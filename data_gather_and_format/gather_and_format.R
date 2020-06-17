# main data source:
cmnts_url <- "https://leedscovidsuggestascheme.commonplace.is/comments.json"
# map of bounds source:
framework_url <- "https://leedscovidsuggestascheme.commonplace.is/content/map.json"

library(rjson)
library(sf)

########## get the area boundary ############# ##################
# the framework determines all the tags/labels and map polygon bounds
framework <- paste0('data/framework_', Sys.Date(), '.json')
download.file(url=framework_url, destfile = framework)

fw <- fromJSON(file=framework)

# get the long/lat
fwm_yx <- matrix(data = unlist(fw$map$boundaries[[1]]$coordinates), ncol = 2, byrow = T)
# reverse order of coordinates from y,x (lat,long) to x,y (long,lat)
fwm <- fwm_yx[,c(2,1)]

# make into sfc object
bounds <- st_sfc(st_polygon(list(fwm[c(1:nrow(fwm),1),]), dim = 'XY'))
st_crs(bounds) <- 4326

# Leeds bounds data are meaningless
plot(bounds)
# don't bother saving

#save_polygon <- '../data/map_bounds.geojson'
#file.remove(save_polygon) # delete because write_sf throws warning for overwrite
#write_sf(bounds, dsn=save_polygon)

# help build HTML
fw$questions

########## get the comments ############# ##################

json_file <- paste0("data/SS_cmnts_", Sys.Date(), ".json")
# download and save with today's date
download.file(cmnts_url, json_file)

# import to R, convert from JSON
cmnts <- rjson::fromJSON(file = json_file, unexpected.escape = "skip")

# fields of interest (LEEDS)
foi <- list(
  comment=       "anythingElse",
  solution_tags= "howImprove",
  name=          "ifASchoolParkOtherPlaceOfInterestPleaseNameIt",
  type =         "whatItIs",
  theme=         "whichAreaThemeBestDescribesYourSuggestion",
  issue_tags=    "whyFeel" )

# fields of interest (BURY)
#foi <- list(
  #issue_tags="whatIsTheProblem",
  #solution_tags="howImprove",
  #want_perm="wouldYouSupportTheseChangesBeingMadeLongTerm",
  #comment="anyOtherCommentsAboutThisLocation",
  #short_desc="whatAreYouCommentingOn")

cmnts_clean <- lapply(cmnts, function(x) {
  # x <- cmnts[[4200]]
  cid <- x$id
  feeling <- x$properties$feeling # 0,25, 50, 75, or 100
  consent_tf <- x$properties$consent
  if( is.null(consent_tf) | length(consent_tf) != 1 ) { consent_tf <- NA}
  subdate <- x$properties$date
  votes <- x$properties$agree$number
  url <- strsplit(x = x$shortUrl, split = "[?]")[[1]][1]
  wgs_lat <- x$geometry$coordinates[2]
  wgs_long <- x$geometry$coordinates[1]
  
  # look for each of the fields of interest, foi
  xfoi <- sapply(foi, function(y) {
    # y <- foi[[2]]
    tmp <- sapply(x$properties$fields, function(z) {
      # z <- x$properties$fields[[1]]
      if( y != z$name ) {
        return(NA)
      }
      return(paste(z$value, collapse = "_,_"))
    })
  })
  
  # fields of interest results
  xfoir <- data.frame(t(apply(xfoi, MARGIN = 2, function(x) {
    if(all(is.na(x))) { return(NA)}
    x[!is.na(x)][[1]]
  })), stringsAsFactors = F)
  
  if( is.na(xfoir$name) ) {
    title <- xfoir$type
  } else {
    title <- xfoir$name
  }
  
  perm <- xfoir$want_perm
  if( is.null(perm)) { perm <- NA}
  comment <- gsub(pattern = "\n", replacement = "<br>", x = xfoir$comment)
  issues_csv <- xfoir$issue_tags
  suggest_csv <- xfoir$solution_tags
  theme <- xfoir$theme
  
  return(data.frame(title=title,
                    cid=cid,
                    feeling=feeling,
                    consent=consent_tf,
                    theme=theme,
                    subdate=subdate,
                    votes=votes,
                    url=url,
                    lat=wgs_lat,
                    long=wgs_long,
                    wantperm=perm,
                    issues=issues_csv,
                    solutions=suggest_csv,
                    comment=comment,
                    stringsAsFactors = F))
})

ss <- do.call('rbind', cmnts_clean)

# fix dates from relative to absolute
now <- Sys.time()
ss$abdate <- NA
dt_in_days_ago <- grep(pattern="days", ss$subdate)
dt_a_day_ago <- grep(pattern="a day", ss$subdate)
dt_in_hours_ago <- grepl(pattern="hours", ss$subdate)
dt_an_hour_ago <- grepl(pattern="an hour", ss$subdate)
dt_in_mins_ago <- grepl(pattern="minutes", ss$subdate)

ss$abdate[dt_in_days_ago] <- strftime(now - (as.integer(unlist(strsplit(x = ss[dt_in_days_ago,"subdate"], split = " days ago"))) * 60 * 60 * 24), "%Y-%m-%d")
ss$abdate[dt_a_day_ago] <- strftime(now - (60 * 60 * 24), "%Y-%m-%d")
ss$abdate[dt_in_hours_ago] <- strftime(now - (as.integer(unlist(strsplit(x = ss[dt_in_hours_ago,"subdate"], split = " hours ago"))) * 60 * 60), "%Y-%m-%d")
ss$abdate[dt_an_hour_ago] <- strftime(now - (60 * 60), "%Y-%m-%d")
ss$abdate[dt_in_mins_ago] <- strftime(now - (as.integer(unlist(strsplit(x = ss[dt_in_mins_ago,"subdate"], split = " minutes ago"))) * 60), "%Y-%m-%d")

# check we got them all otherwise resolve
if( any(is.na(ss$abdate)) ) {
  if( file.exists('data/cid_abdates_key.RData') ) {
    load(file='data/cid_abdates_key.RData') # cid_abdates
    fss <- merge(ss, cid_abdates, by='cid')
    fixables <- is.na(fss$abdate.x) & !is.na(fss$abdate.y)
    fss$abdate.x[fixables] <- fss$abdate.y[fixables]
    fss$abdate.y <- NULL
    colnames(fss)[ncol(fss)] <- 'abdate'
    ss <- fss
  } else {
    # May 11th was launch, spread out 'a month ago', by index
    # May 22nd is the earliest date data we can confirm
    launch_date <- '2020-05-15'
    num_date_na <- sum(is.na(ss$abdate))
    num_days <- as.Date('2020-05-22') - as.Date(launch_date)
    estim_dates <- rep(as.Date(launch_date) + seq(num_days) - 1, each=num_date_na/as.integer(num_days))
    # multiple has gaps, fill
    full_estim_dates <- c(rep(launch_date, num_date_na - length(estim_dates)), strftime(estim_dates))
    ss$abdate[is.na(ss$abdate)] <- full_estim_dates
    
    # build date index to save relative dates as absolute
    cid_abdates <- ss[,c('cid', 'abdate')]
    save(cid_abdates, file='data/cid_abdates_key.RData')
  }
}

# check again
any(is.na(ss$abdate))
ss$subdate[is.na(ss$abdate)]

# filter out bad data
# hack, but works for now
ss$comment <- iconv(ss$comment, from='latin1', to='utf8',sub = "")

# replace bit.ly urls with proper
base_url <- "https://leedscovidsuggestascheme.commonplace.is/comments/"
ss$url <- paste0(base_url, ss$cid)

# export
#write.table(ss, file = 'www/data/data.tsv', quote = F, sep = "\t", row.names = F)
write(toJSON(split(ss, 1:nrow(ss))), '../data/cmnts.json')
