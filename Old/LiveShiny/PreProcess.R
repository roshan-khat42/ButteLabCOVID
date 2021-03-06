######################################################################
######################################################################
#    PreProcessing
######################################################################
######################################################################

######################################################################
# Setup Notebook
######################################################################

# Load Libraries
library(shinydashboard)
library(usmap)
library(tidyverse)
library(tidycensus)
library(maps)
library(sf)
library(ggrepel)
library(stringr)
library(shinyjs)
library(fmsb) #for percentile
library(scales) #so we dont have scientific notation
library(roll)
library(zoo)
devtools::install_github("UrbanInstitute/urbnmapr") # Uncomment
library(urbnmapr) #devtools::install_github("UrbanInstitute/urbnmapr")
library(USAboundaries) # to get state boundaries
# library(mapproj) albers projection? -- seems non-trivial

# Load Elliott Libraries
library(plotly)
library(ggplot2)

# Read in the NY Times Data
stateDat <- read_csv(url("https://raw.githubusercontent.com/nytimes/covid-19-data/master/us-states.csv")) # Uncomment
countyDat <- read_csv(url("https://raw.githubusercontent.com/nytimes/covid-19-data/master/us-counties.csv")) # Uncomment

# stateDat <- read_csv(file = "./DataFiles/us-states.csv") # Comment
# countyDat <- read_csv(file = "./DataFiles/us-counties.csv") # Comment

# Remove the unknown counties -- we don't know where to assign these
countyDat <- countyDat %>%
  filter(county != "Unknown")

# Remove territories
territories = c("Guam", "Northern Mariana Islands", "Puerto Rico", "Virgin Islands")
stateDat = stateDat[-which(stateDat$state %in% territories),]

#class(stateDat)
#View(stateDat)  # Puts data in R Studio view

######################################################################
# Clean the NY Times Data
######################################################################
# Fix NYC
countyDat[which(countyDat$county == "New York City" & countyDat$state == "New York"),"fips"] <- "NYC"
# Fix KC Mo -- combine all the counties that intersect KC with KC
kcCounties = c("Cass", "Clay", "Jackson", "Platte", "Kansas City")
kcCountyData = countyDat[which(countyDat$county %in% kcCounties & countyDat$state == "Missouri"),]

kcCountyData = kcCountyData %>%
  select(-c(county,state,fips))

kcCountyData <- kcCountyData %>%
  group_by(date) %>%
  summarise_all(sum)

kcCountyData = tibble(date = kcCountyData$date, county = "Kansas City", state = "Missouri", fips = "KC", cases = kcCountyData$cases, deaths = kcCountyData$deaths)
countyDat = countyDat[-which(countyDat$county %in% kcCounties & countyDat$state == "Missouri"),]
countyDat = rbind(countyDat,kcCountyData)

######################################################################
# Use US Census API to get Population Numbers
######################################################################
# # Get census API key from: https://api.census.gov/data/key_signup.html
# census_api_key("779c8b33af41fa4dbf19a22405c65c780fd379ac")
# 
# # Get population estimates per county from the US Census API
# popEst <- get_estimates(geography = "county", product = "population")
# popEst <- popEst %>%
#   filter(variable == "POP")
# 
# # Fix NYC
# nycCounties = c("New York County, New York", "Kings County, New York", "Queens County, New York", "Bronx County, New York", "Richmond County, New York")
# nycCounts = sum(popEst[which(popEst$NAME %in% nycCounties),"value"])
# nycCounts = tibble(NAME = "New York City, New York", GEOID = "NYC", variable = "POP", value = nycCounts)
# popEst = popEst[-which(popEst$NAME %in% nycCounties),]
# popEst = rbind(popEst,nycCounts)
# 
# # Fix KC Mo -- here, combine Cass, Clay, Jackson and Platte with KC
# kcCounties = c("Cass County, Missouri", "Clay County, Missouri", "Jackson County, Missouri", "Platte County, Missouri")
# kcCounts = sum(popEst[which(popEst$NAME %in% kcCounties),"value"])
# kcCounts = tibble(NAME = "Kansas City, Missouri", GEOID = "KC", variable = "POP", value = kcCounts)
# popEst = popEst[-which(popEst$NAME %in% kcCounties),]
# popEst = rbind(popEst,kcCounts)

popEst <- read_csv(file = "./DataFiles/census_county_populations.csv")
# popEst <- read_csv(file = "./LiveShiny/DataFiles/census_county_populations.csv")

statePopEst <- popEst %>% 
  separate(NAME, c("County", "State"), sep = ", ") %>%
  group_by(State) %>% 
  summarise(value = sum(value))

######################################################################
# Get the number of new cases and deaths per day
######################################################################
# New cases per day
countyDat <- countyDat %>% 
  group_by(county,state,fips) %>% 
  mutate(NewCases = cases - lag(cases, default = 0, order_by = date))

#New deaths per day
countyDat <- countyDat %>% 
  group_by(county,state,fips) %>% 
  mutate(NewDeaths = deaths - lag(deaths, default = 0, order_by = date))

#Now for the states
stateDat <- stateDat %>% 
  group_by(state) %>% 
  mutate(NewCases = cases - lag(cases, default = 0, order_by = date))
stateDat <- stateDat %>% 
  group_by(state) %>% 
  mutate(NewDeaths = deaths - lag(deaths, default = 0, order_by = date))

######################################################################
# Join the US Census data with the NY Times data
######################################################################
# Join Data
countyDat <- left_join(countyDat, popEst, by = c("fips" = "GEOID"))

countyDat <- countyDat %>%
  filter(!is.na(value)) # Here we are removing all the "Unknown" -- need to update this.... potentially use some of Paul's suggestions?

# Get cases and deaths per million population
countyDat <- countyDat %>%
  mutate(casesPerMillion = (cases/value)*1000000) %>%
  mutate(deathsPerMillion = (deaths/value)*1000000) %>%
  mutate(NewCasesPerMillion = (NewCases/value)*1000000) %>%
  mutate(NewDeathsPerMillion = (NewDeaths/value)*1000000)

# Now do for the states
stateDat <- left_join(stateDat, statePopEst, by = c("state" = "State"))
# Get cases and deaths per million population
stateDat <- stateDat %>%
  mutate(casesPerMillion = (cases/value)*1000000) %>%
  mutate(deathsPerMillion = (deaths/value)*1000000) %>%
  mutate(NewCasesPerMillion = (NewCases/value)*1000000) %>%
  mutate(NewDeathsPerMillion = (NewDeaths/value)*1000000)

######################################################################
# Set t = 0 to the first observed case in each county
######################################################################
# Set t=0 to the data of >= 10 cases
suppressWarnings( # this is noisy for N/As
  time_zero <- countyDat %>%
    group_by(state, county) %>%
    summarise(first_case = min(date[which(cases>=10)])) %>%
    ungroup
)


# Set a new column for the time elapsed between the date column and the t=0 date for each row
countyDat <- countyDat %>%
  left_join(time_zero, by = c("state", "county")) %>%
  mutate(time = as.numeric(date - first_case))

######################################################################
# State-mandated events -- mapped by Vivek, Travis, and Arman
######################################################################
# Read in the events mapped by Vivek, Travis and Arman
stateEvents <- read_csv(file = "./DataFiles/state-events.csv")
# stateEvents <- read_csv(file = "./LiveShiny/DataFiles/state-events.csv")

# Spread the data so we get an event in each column and the relevant date (if available) as the value
stateEvents <- stateEvents %>%
  pivot_wider(names_from = Event, values_from = Date)

# Join the state counts data with the state events data
stateDat <- stateDat %>%
  left_join(stateEvents, by = c("state" = "State_Name"))

######################################################################
# Calculated Doubling Time (Counties) -- Implemented by Travis Zack
######################################################################
#TRAVIS ZACK###
dbl_df <- data.frame(county=as.character(),state=as.character(),cur_double=as.numeric())
# Initialize parameters
min_cases_tot <- 100
min_cases_cur <- 10
all_states <- unique(countyDat$state)
rollnum <- 7
weights <- 0.9^(rollnum:1)
maxdouble <- 14
i <-1
countyDat$double <- as.double(NA)

for (j in 1:length(all_states)){
  statefocus <- all_states[j]
  idx_state <- which(countyDat$state == statefocus)
  caseDatastate <- countyDat[idx_state,]
  caseDatastate$double <- as.double(NA)
  all_counties <- unique(caseDatastate$county)
  n <- length(all_counties)
  keep_counties <- unique(caseDatastate[which(caseDatastate$cases>=min_cases_tot),]$county)
  most_recent_dbl_df <- data.frame(county=all_counties,state=rep(statefocus,n,1),cur_double=rep(as.double(NA),n,1))
  for (i in 1:length(all_counties)){
    idx_cnty <- which(caseDatastate$county==all_counties[i])
    max_cnty <- max(caseDatastate$cases[idx_cnty],na.rm=TRUE)
    if (max_cnty>=min_cases_tot){
      county_focus = c(all_counties[i])
      cnty_cur <- caseDatastate[idx_cnty,]
      #This is to drop all dates with cumulative cases less than some value to remove the really
      #unstable stuff at the beginning of the growth curves.... Worth fiddling with
      bad_idx <- which(cnty_cur$cases<=min_cases_tot)
      resultweighted <- roll_lm(as.integer(cnty_cur$date), log2(cnty_cur$cases), rollnum, weights)
      doubling <- 1/resultweighted$coefficients[,2]
      #doubling[is.na(doubling)] <- 0
      rolldata <- data.frame(double = doubling,
                             date = cnty_cur$date )
      #set extreme values as Na
      if (is.na(any(rolldata$double>1e8))==FALSE) {
        rolldata$double[which(rolldata$double >1e8)] <- as.double(NA)
      }
      if (is.na(any(rolldata$double< -1e8))==FALSE) {
        rolldata$double[which(rolldata$double < -1e8)] <- as.double(NA)
      }
      rolldata$double[bad_idx] <- as.double(NA)
      #interpolate NA to average of surrounding values
      rolldata$double <- (na.locf(rolldata$double,na.rm=FALSE) + na.locf(rolldata$double,fromLast=TRUE,na.rm=FALSE))/2
      caseDatastate$double[idx_cnty] <- rolldata$double
      most_recent_dbl_df$cur_double[i] = tail(rolldata$double,n=1)
    }
    countyDat$double[idx_state] <- caseDatastate$double
  }
  dbl_df <- rbind(dbl_df,most_recent_dbl_df)
}
#dbl_df is a dataframe with just the most recent doubling time estimates for easy grabing
#instead of adding the "double" column to countyDat, created countyDat1 so I didnt mess anything else up
#####END OF DOUBLING TIME CODE##################################

######################################################################
# Calculated Doubling Time (States) -- Implemented by Doug (based on Travis' code)
######################################################################
dbl_df_state <- data.frame(state=as.character(),cur_double=as.numeric())
# Initialize parameters
min_cases_tot <- 100
min_cases_cur <- 10
all_states <- unique(stateDat$state)
rollnum <- 7
weights <- 0.9^(rollnum:1)
maxdouble <- 14
i <-1
stateDat$double <- as.double(NA)

caseDatastate <- stateDat
caseDatastate$double <- as.double(NA)
all_states <- unique(caseDatastate$state)
n <- length(all_states)
keep_states <- unique(caseDatastate[which(caseDatastate$cases>=min_cases_tot),]$state)
most_recent_dbl_df_state <- data.frame(state=all_states,cur_double=rep(as.double(NA),n,1))
for (i in 1:length(all_states)){
  idx_state <- which(caseDatastate$state==all_states[i])
  max_state <- max(caseDatastate$cases[idx_state],na.rm=TRUE)
  if (max_state>=min_cases_tot){
    state_focus = c(all_states[i])
    state_cur <- caseDatastate[idx_state,]
    #This is to drop all dates with cumulative cases less than some value to remove the really
    #unstable stuff at the beginning of the growth curves.... Worth fiddling with
    bad_idx <- which(state_cur$cases<=min_cases_tot)
    resultweighted <- roll_lm(as.integer(state_cur$date), log2(state_cur$cases), rollnum, weights)
    doubling <- 1/resultweighted$coefficients[,2]
    #doubling[is.na(doubling)] <- 0
    rolldata <- data.frame(double = doubling,
                           date = state_cur$date )
    #set extreme values as Na
    if (is.na(any(rolldata$double>1e8))==FALSE) {
      rolldata$double[which(rolldata$double >1e8)] <- as.double(NA)
    }
    if (is.na(any(rolldata$double< -1e8))==FALSE) {
      rolldata$double[which(rolldata$double < -1e8)] <- as.double(NA)
    }
    rolldata$double[bad_idx] <- as.double(NA)
    #interpolate NA to average of surrounding values
    rolldata$double <- (na.locf(rolldata$double,na.rm=FALSE) + na.locf(rolldata$double,fromLast=TRUE,na.rm=FALSE))/2
    caseDatastate$double[idx_state] <- rolldata$double
    most_recent_dbl_df_state$cur_double[i] = tail(rolldata$double,n=1)
  }
  stateDat$double[idx_state] <- caseDatastate$double[idx_state]
}
dbl_df_state <- rbind(dbl_df_state,most_recent_dbl_df_state)
#dbl_df is a dataframe with just the most recent doubling time estimates for easy grabing
#instead of adding the "double" column to countyDat, created countyDat1 so I didnt mess anything else up
#####END OF DOUBLING TIME CODE#################################

######################################################################
# ICU BED Occupancy (Counties) -- Implemented by Travis Zack
######################################################################
#Based on cases over preceding period

#importing ICU bed data
ICU <- read.csv('./DataFiles/data-ICU-beds.txt')

# Fix NYC
nycCounties = c("New York", "Kings", "Queens", "Bronx", "Richmond")
nycCounts = colSums(ICU[which(ICU$County %in% nycCounties & ICU$State == "New York"),c("ICU.Beds","Total.Population","Population.Aged.60.","Percent.of.Population.Aged.60.")])
nycCounts = data.frame(State = "New York", County = "New York City", ICU.Beds = nycCounts["ICU.Beds"], Total.Population = nycCounts["Total.Population"],
                       Population.Aged.60. = nycCounts["Population.Aged.60."], Percent.of.Population.Aged.60. = as.double(NA), Residents.Aged.60..Per.Each.ICU.Bed = as.double(NA))
ICU = ICU[-which(ICU$State %in% "New York" & ICU$County %in% nycCounties),]
ICU = rbind(ICU,nycCounts)

# Fix KC Mo -- here, combine Cass, Clay, Jackson and Platte with KC
kcCounties = c("Cass", "Clay", "Jackson", "Platte")
kcCounts = colSums(ICU[which(ICU$County %in% kcCounties & ICU$State == "Missouri"),c("ICU.Beds","Total.Population","Population.Aged.60.","Percent.of.Population.Aged.60.")])
kcCounts = data.frame(State = "Missouri", County = "Kansas City", ICU.Beds = kcCounts["ICU.Beds"], Total.Population = kcCounts["Total.Population"],
                      Population.Aged.60. = kcCounts["Population.Aged.60."], Percent.of.Population.Aged.60. = as.double(NA), Residents.Aged.60..Per.Each.ICU.Bed = as.double(NA))
ICU = ICU[-which(ICU$State %in% "Missouri" & ICU$County %in% kcCounties),]
ICU = rbind(ICU,nycCounts)

##DOUG --> Can you do this smarter :) Just want to add the ICU bed data for each county to our table
#Also have to refigure out the NYC thing likely
countyDat$ICUbeds <- as.double(NA)
countyDat$icu_bed_occ <- as.double(NA)
for (i in 1:nrow(ICU)){
  idx_cur <- which((countyDat$state==ICU$State[i]) & (countyDat$county==ICU$County[i]))
  if (length(idx_cur)>0){
    countyDat$ICUbeds[idx_cur] <- ICU$ICU.Beds[i]
  }
  
}

## Vivek Comment: Assumes 4.4% of new cases are admitted, 
## 30% of admitted patients escalate to the ICU, 
## and all ICU patients spend 9 days (time to discharge or death)

icu_los <- 9
hosp_frac <-0.044
icu_frac <- 0.3
min_cases <- 100

all_states <- unique(countyDat$state)
# start_time <- Sys.time()
for (j in 1:length(all_states)){
  statefocus <- all_states[j]
  idx_state <- which(countyDat$state == statefocus)
  caseDatastate <- countyDat[idx_state,]
  caseDatastate$icu_bed_occ <- as.double(NA)
  all_counties <- unique(caseDatastate$county)
  n <- length(all_counties)
  keep_counties <- unique(caseDatastate[which(caseDatastate$cases>=min_cases),]$county)
  most_recent_dbl_df <- data.frame(county=all_counties,state=rep(statefocus,n,1),cur_double=rep(as.double(NA),n,1))
  for (i in 1:length(all_counties)){
    idx_cnty <- which(caseDatastate$county==all_counties[i])
    cnty_cur <- caseDatastate[idx_cnty,]
    if (nrow(cnty_cur)>(icu_los+1)){
      vec_st <- cnty_cur$cases[1:(icu_los+1)]
      cnty_cur$icu_bed_occ = rollsum(x = cnty_cur$cases, icu_los, align = "right", fill = as.double(NA))*hosp_frac*icu_frac
      vec_st_mut <- vec_st
      for (k in 1:icu_los){
        vec_st_mut[k] <- sum(vec_st[1:k])*hosp_frac*icu_frac
      }
      cnty_cur$icu_bed_occ[1:(icu_los+1)] <- vec_st_mut
      
      # If we see a jump over 200% at t = 2 days with reference of t = 1 days and then back down under 100% at t = 3 days with t = 1 days as reference, set to N/A and interpolate to avg of surrounding values
      # pctIncrease = cnty_cur %>%
      #   mutate(pctIncrease1 = icu_bed_occ - lag(icu_bed_occ, n = 1, default = first(icu_bed_occ))) %>%
      #   mutate(pctIncrease2 = icu_bed_occ - lag(icu_bed_occ, n = 2, default = first(icu_bed_occ)))
      
      # If we see a jump over 200% at t = 2 days with reference of t = 1 days and then back down under 100% at t = 3 days with t = 1 days as reference, set to N/A and interpolate to avg of surrounding values
      pctIncrease = cnty_cur %>%
        mutate(pctIncrease1 = icu_bed_occ / lag(icu_bed_occ, n = 1, default = first(icu_bed_occ))) %>%
        mutate(pctIncrease2 = icu_bed_occ / lag(icu_bed_occ, n = 2, default = first(icu_bed_occ)))
      
      #set extreme values as Na (peaks)
      if (is.na(any(abs(pctIncrease$pctIncrease1)<0.5 & abs(pctIncrease$pctIncrease2)>=1))==FALSE) {
        cnty_cur$icu_bed_occ[which(abs(pctIncrease$pctIncrease1)<0.5 & abs(pctIncrease$pctIncrease2)>=1) - 1] <- as.double(NA)
      }
      # if (is.na(any(abs(pctIncrease$pctIncrease1)>2 & abs(pctIncrease$pctIncrease2)<1))==FALSE) {
      #   cnty_cur[which(abs(pctIncrease$pctIncrease1)>2 & abs(pctIncrease$pctIncrease2)<1) - 1,'icu_bed_occ'] <- NA
      # }
      
      # #set extreme values as Na
      # if (is.na(any(pctIncrease$pctIncrease1>3 & pctIncrease$pctIncrease2>3))==FALSE) {
      #   cnty_cur[which(pctIncrease$pctIncrease1>3 & pctIncrease$pctIncrease2>3),'icu_bed_occ'] <- NA
      # }
      # if (is.na(any(pctIncrease$pctIncrease1< -3 & pctIncrease$pctIncrease2< -3))==FALSE) {
      #   cnty_cur[which(pctIncrease$pctIncrease1< -3 & pctIncrease$pctIncrease2< -3),'icu_bed_occ'] <- NA
      # }
      #interpolate NA to average of surrounding values
      cnty_cur$icu_bed_occ <- (na.locf(cnty_cur$icu_bed_occ,na.rm=FALSE) + na.locf(cnty_cur$icu_bed_occ,fromLast=TRUE,na.rm=FALSE))/2
      
      caseDatastate$icu_bed_occ[idx_cnty] <- cnty_cur$icu_bed_occ
    }
  }
  countyDat$icu_bed_occ[idx_state] <- caseDatastate$icu_bed_occ
}
# Convert to percent occupied
countyDat$perc_icu_occ <- 100*(countyDat$icu_bed_occ/countyDat$ICUbeds)
# Change infinite values to NA
countyDat$perc_icu_occ[is.infinite(countyDat$perc_icu_occ)] <- as.double(NA)


# end_time <- Sys.time()
# print(end_time-start_time)

######################################################################
# ICU BED Occupancy (Counties) -- Counties implemented by Travis -- extended by Doug
######################################################################

# Get the beds per state
ICUstate <- ICU %>%
  group_by(State) %>%
  summarise(ICU.Beds = sum(ICU.Beds,na.rm = T))

##DOUG --> Can you do this smarter :) Just want to add the ICU bed data for each county to our table
#Also have to refigure out the NYC thing likely
stateDat$ICUbeds <- as.double(NA)
stateDat$icu_bed_occ <- as.double(NA)
for (i in 1:nrow(ICUstate)){
  idx_cur <- which((stateDat$state==ICUstate$State[i]))
  if (length(idx_cur)>0){
    stateDat$ICUbeds[idx_cur] <- ICUstate$ICU.Beds[i]
  }
  
}

all_states <- unique(stateDat$state)
for (i in 1:length(all_states)){
  statefocus <- all_states[i]
  idx_state <- which(stateDat$state == statefocus)
  caseDatastate <- stateDat[idx_state,]
  # idx_state <- which(caseDatastate$county==all_counties[i])
  state_cur <- caseDatastate
  icuBedState <- caseDatastate$icu_bed_occ
  if (nrow(state_cur)>(icu_los+1)){
    vec_st <- state_cur$cases[1:(icu_los+1)]
    state_cur$icu_bed_occ = rollsum(x = state_cur$cases, icu_los, align = "right", fill = as.double(NA))*hosp_frac*icu_frac
    vec_st_mut <- vec_st
    for (k in 1:icu_los){
      vec_st_mut[k] <- sum(vec_st[1:k])*hosp_frac*icu_frac
    }
    state_cur$icu_bed_occ[1:(icu_los+1)] <- vec_st_mut
    
    # caseDatastate$icu_bed_occ[idx_state] <- state_cur$icu_bed_occ
    icuBedState <- state_cur$icu_bed_occ
  }
  # stateDat$icu_bed_occ[idx_state] <- caseDatastate$icu_bed_occ[idx_state]
  stateDat$icu_bed_occ[idx_state] <- icuBedState
}


# Convert to percent occupied
stateDat$perc_icu_occ <- 100*(stateDat$icu_bed_occ/stateDat$ICUbeds)
# Change infinite values to NA
stateDat$perc_icu_occ[is.infinite(stateDat$perc_icu_occ)] <- as.double(NA)

######################################################################
# Load maps
######################################################################
states_sf <- get_urbn_map(map = "states", sf = TRUE)

counties_sf <- get_urbn_map("counties", sf = TRUE)
counties_sf$county_name = gsub(pattern = " County", replacement = "", x = counties_sf$county_name)
# Fix for NYC
nycCounties = c("New York","Kings","Queens","Bronx","Richmond")

# Throws a warning when we modify: st_crs<- : replacing crs does not reproject data; use st_transform for that
# This is ok
suppressWarnings(counties_sf[which(counties_sf$state_name == "New York" & counties_sf$county_name %in% nycCounties),]$county_name <- "New York City")
suppressWarnings(counties_sf[which(counties_sf$state_name == "New York" & counties_sf$county_name == "New York City"),]$county_fips <- "NYC")

# Fix for KC
kcCounties = c("Cass", "Clay", "Jackson", "Platte", "Kansas City")
suppressWarnings(counties_sf[which(counties_sf$state_name == "Missouri" & counties_sf$county_name %in% kcCounties),]$county_name <- "Kansas City")
suppressWarnings(counties_sf[which(counties_sf$state_name == "Missouri" & counties_sf$county_name == "Kansas City"),]$county_fips <- "KC")

######################################################################
# Default Parameters for polotting initial maps (then we update dynamically)
######################################################################
defaultDate1 = as.Date("2020-03-01")
defaultDate2 = as.Date(max(stateDat$date))
defaultState = "Hawaii"
defaultValPlot = "cases"

######################################################################
# Misc Functions
######################################################################
# convert data to percentiles
perc.rank <- function(x) trunc(base::rank(x))/length(x)
colorPallette = colorRamp(colors = c("#ffffff", "#ffbe87", "#e6550d"))
######################################################################

######################################################################
# US Map
######################################################################

# Filter the date range for the data to show on the US map
# Pull in the state data
req(stateDat)
# Get the appropriate date range
usmapDat1 <- subset(stateDat, as.character(date) == as.character(defaultDate1))
usmapDat2 <- subset(stateDat, as.character(date) == as.character(defaultDate2))
# Find the states for that don't have data in the 1st timepoint but do have data in the 2nd timepoint
toAdd = usmapDat2[which(!usmapDat2$state %in% usmapDat1$state),]
if(nrow(toAdd)>0){
  toAdd[,c("cases","deaths")] = 0
  usmapDat1 = rbind(usmapDat1,toAdd)
}
usmapDat2 <- usmapDat2 %>% 
  arrange(state)
usmapDat1 <- usmapDat1 %>% 
  arrange(state)

# Get the difference between the two date ranges (e.g. we want the number of cases or deaths for that date range)
usmapDat2$cases = usmapDat2$cases - usmapDat1$cases
usmapDat2$deaths = usmapDat2$deaths - usmapDat1$deaths

# Scale to percentile
usmapDat2$value = perc.rank(pull(usmapDat2[,defaultValPlot]))
usmapDat2$value = usmapDat2$value*100

# Get the state boundaries
req(states_sf)
usmapDat2 <- states_sf %>%
  left_join(usmapDat2,by = c("state_name" = "state")) %>%
  # transform the coordinates of the map (by default it is very squished)
  st_transform(crs = paste0("+proj=aea +lat_1=29.5 +lat_2=45.5 +lat_0=23 +lon_0=-96 +x_0=0 +y_0=0 +ellps=GRS80 +datum=NAD83 +units=m +no_defs"))



######################################################################
# Save Workspace to file
######################################################################
save.image(file = "./DataFiles/CovidCountiesWorkspace.RData")
