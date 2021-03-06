#!/bin/bash

# Title:        dailymotionMirror
# Description:  Uses the dailymotion api to mirror videos from a given youtube playlist downloaded via youtube-dl
# Disclaimer:   The author of this script takes no responsibility for any prohibited content that is uploaded to dailymotion as a result of using this script.

# Version Tracking
scriptVersionNo=0.8.4

# Error handler just to print where fault occurred.  But code will still continue
errorHandler() {
    errInfo="Error on line $1"
    echo "$errInfo" 1>&2
}
trap 'errorHandler $LINENO' ERR

setConstants() {

    # Standard Exit Codes Enum
    ec_Success=0
    ec_Error=1

    # Custom Exit Codes Enum
    ec_ContinueNext=3
    ec_BreakLoop=4
    ec_Yes=5
    ec_No=6

    # enums for wait reason
    wr_minimumTime=0
    wr_hourlyLimit=1
    wr_durationLimit=2
    wr_dailyLimit=3

    # Get the source of the current script
    #calledBy="$(ps -o comm= $PPID)"
    scriptDir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    scriptFile=$(basename "$0")
    scriptName=${scriptFile%.*}

    # Files and directories
    selfSourceCodeHost="https://raw.githubusercontent.com/skytunnel/dailymotionMirror"
    selfSourceCodeBranch="master"
    selfSourceCodeFile="dailymotionMirror.sh"
    ytdlSource="https://yt-dl.org/downloads/latest/youtube-dl"
    ytdl="/usr/local/bin/youtube-dl"
    ytdlInfoExt="info.json"
    scriptNameClean=${scriptName//[^a-zA-Z0-9_]/}
    cronJobFile="/etc/cron.d/$scriptNameClean"
    instanceLockFile=$scriptDir/.$scriptName.pid
    propertiesFile=$scriptDir/$scriptName.prop
    urlsFile=$scriptDir/$scriptName.urls
    videoListFile=$scriptDir/.playlist
    videoCacheFile=$scriptDir/.cache
    archiveFile=$scriptDir/.downloaded
    allowanceFile=$scriptDir/.allowance
    publishedUploadsFile=$scriptDir/published.json
    publishedUploadsFileCSV=$scriptDir/published.csv
    logFile=$scriptDir/$scriptName.log
    logArchive=$(date +"%Y%m%d_%H%M%S").log
    outputDir=$scriptDir/$scriptName/ # Defaults to this when not set on prop file
    backupDir="backup"
    keepLogsDir="logs"
    keepVideosDir="done"
    failedVideosDir="failed"

    # DailyMotion's automated upload limits...
    # https://developer.dailymotion.com/api#guidelines
    # https://faq.dailymotion.com/hc/en-us/articles/115009030568-Upload-policies
    dmDurationAllowanceSTR="2 hours"            # Dailymotion.com upload duration allowance
    dmDurationAllowanceExpirySTR="24 hours"     # How long before duration expires and can be used again
    dmVideosPerDay=10                           # Max number of videos per day
    dmVideosPerDayForVerifiedPartners=96        # Max number of videos per day on Verified Partner Accounts
    #dmVideoAllowance=4 (no longer enforced)    # Dailymotion.com video count allowance per hour (OLD LIMIT NO LONGER IN USE - Use to be 4 uploads per hour)
    dmVideoAllowanceExpirySTR="60 minutes"      # How long before video count expires and can be used again
    dmExpiryToleranceTimeSTR="30 seconds"       # Additional amount of seconds to wait on top of the dailymotion allowance expiry (in order to avoid exceeding limits)
    dmWaitTimeBetweenUploadsSTR="10 seconds"    # The minimum seconds between one upload ending and another beginning
    waitTimeBeforeDownloadingSTR="2 hours"      # How much time to allow the download before the allowance is available
    waitTimeBeforeUploadingSTR="1 hour"         # How much time to allow the upload before the allowance is available
    quitWhenUploadWindowIsWithinSTR="3 hours"   # If the upload window doesn't start till within this time before the next scheduled run, then just quit and let the next scheduled run process it (avoids it starting a new window without using up the allowance of the previous window)
    dmMaxTitleLength=255                        # Max characters for video title
    dmMaxDescription=3000                       # Max characters for video description
    dmMaxDescriptionForPartners=5000            # Max characters for video description on Partner Accounts
    dmMaxTags=150                               # Max number of tags on a video

    # https://developer.dailymotion.com/api
    # "Video upload through the API is also limited to:
    #   * 4 videos per hour
    #   * 2 hours of videos (total) per day
    #   * 60 minutes per video
    #   * 2 GB per video
    # These limits may change on a case-by-case basis.
    # To check your limits at the video level, you can request the
    # limits field on your own user using the API, like this:
    # /me?fields=limits (you will need to be authenticated)."

    # Convert times to seconds
    dmDurationAllowance=$(timeInSeconds "$dmDurationAllowanceSTR")
    dmDurationAllowanceExpiry=$(timeInSeconds "$dmDurationAllowanceExpirySTR")
    dmVideoAllowanceExpiry=$(timeInSeconds "$dmVideoAllowanceExpirySTR")
    dmExpiryToleranceTime=$(timeInSeconds "$dmExpiryToleranceTimeSTR")
    dmWaitTimeBetweenUploads=$(timeInSeconds "$dmWaitTimeBetweenUploadsSTR")
    waitTimeBeforeDownloading=$(timeInSeconds "$waitTimeBeforeDownloadingSTR")
    waitTimeBeforeUploading=$(timeInSeconds "$waitTimeBeforeUploadingSTR")
    quitWhenUploadWindowIsWithin=$(timeInSeconds "$quitWhenUploadWindowIsWithinSTR")

}

initialization() {

    # Get/Set Program Constants
    setConstants

    # Read program's given input arguments
    inputArguments

    # Start up checks to ensure setup complete and dependencies installed
    [ $optSkipStartupChecks = Y ] || startupChecks

    # Choose which procedure to run
    procedureSelection

}

# function to print an error
function printError() {
    errMsg="$@"
    if [ -z "$errMsg" ]; then
        errMsg="Unspecified Error!"
    else
        errMsg="ERROR: $errMsg"
    fi
    echo "$errMsg" 1>&2
}

# function to log error and exit
function raiseError() {
    printError "$@"
    exitRoutine
}

# function to test for numeric value
function isNumeric() {
    case "$@" in
        ''|*[!0-9]*) return $ec_Error ;;
    esac
    return $ec_Success
}

# function to test for date value
function isDate() {
    [ -z "$@" ] && return $ec_Error
    date -d "$@" > /dev/null 2>&1 || return $ec_Error
    return $ec_Success
}

# Function convert a time string to number of seconds
function timeInSeconds() {
    echo $(date +%s -u -d "$(date +%F -d @0) $@")
}

# function to pause untill user clicks enter
function pause() {

    # Only on interactive mode
    [ -t 0 ] || return 0

    # prompt text
    prompText="Press enter to continue..."
    [ -z "$@" ] || prompText="$@"

    # Wait for enter key
    read -s -r -p "$prompText"

    # Line break to fix inline entry from above
    echo ""
}


# function to prompt user for yes/no response
function promptYesNo() {

    #Initial Prompt
    echo ""
    read -s -r -p "$@ [Y/n] " -n 1 userResponse

    # Check and wait for valid response
    while true; do
        # Only alow Y/N entry
        userResponse=${userResponse//[^YyNn]/}
        while [ -z "$userResponse" ]; do
            read -s -r -n 1 userResponse
            userResponse=${userResponse//[^YyNn]/}
        done
        echo -n "$userResponse"

        # User must press Enter to confirm
        read -s -r -n 1 userConfirm
        [ $? -eq 0 ] && [ -z "$userConfirm" ] && break

        # Remove previous response
        echo -n $'\b'" "$'\b'

        # Pass new response into loop
        userResponse=$userConfirm
    done
    echo "" # Insert new line

    # Interpret and return response
    returnResponse=$ec_Error
    case $userResponse in
        Y|y) returnResponse=$ec_Yes ;;
        N|n) returnResponse=$ec_No ;;
    esac
    return $returnResponse

}

# function to manage query of json file
function queryJson() {
    jsElementName="$1"
    jsonInput="$2"

    # required parameters
    if [ -z "$jsElementName" ]; then
        printError "Arg 1 requires json element route name"
        exit 1
    fi
    if [ -z "$jsonInput" ]; then
        printError "Arg 2 requires json file or string for $jsElementName query"
        exit 1
    fi

    # prefix dot
    [ ${jsElementName:0:1} = "." ] || jsElementName=.$jsElementName

    # file or string?
    if [ -f "$jsonInput" ]; then
        # Ensure file is not empty
        if ! [ -s "$jsonInput" ]; then
            printError "json file is empty! Cannot Query: $jsonInput"
            exit 1
        fi

        # Query result
        jq --raw-output \
            --compact-output \
            "$jsElementName" \
            "$jsonInput"
    else
        # Ensure string is not blank
        if [ -z "${jsonInput// }" ]; then
            printError "json string is empty! Cannot Query!"
            exit 1
        fi

        # Query result
        jq --raw-output \
            --compact-output \
            "$jsElementName" \
            <<< "$jsonInput"
    fi
}

rootRequired() {

    # Procedure to exit with error when root access is required
    #if [ "$EUID" -ne 0 ]; then
    if ! [ $(sudo echo 0 ) ]; then
        raiseError "Root access is required to run this command"
    fi

}

startupChecks() {

    # Default return
    startupConfirmed=Y

    # Ensure required packages exist
    if [ -z $(command -v curl) ]; then
        startupConfirmed=N
        printError "curl command not found!  Please install"
    fi
    if [ -z $(command -v jq) ]; then
        startupConfirmed=N
        printError "jq command not found!  Please install"
    fi
    if [ -z $(command -v avconv) ] && [ -z $(command -v ffmpeg) ]; then
        startupConfirmed=N
        printError "ffmpeg or avconv commands not found!  Please install"
    fi
    if ! [ -f $ytdl ]; then
        startupConfirmed=N
        printError "youtube-dl command not found!  Please install"
    fi
    if [ -z $(command -v crontab) ]; then
        startupConfirmed=N
        printError "crontab command not found!  Please install"
    fi

    # Ensure properties file exists
    if ! [ -f "$propertiesFile" ]; then
        startupConfirmed=N
        printError "Properties file not found!  Use the --edit-prop command to setup"
    fi

    # Trigger First-Time-Setup if anything is missing
    if [ $startupConfirmed != Y ]; then
        echo ""
        firstTimeSetup
        exit
    fi

    # Warn if cron schedule not setup
    if ! [ -f "$cronJobFile" ]; then
        raiseError "No cron schedule detected!  Use the --edit-schedule command to setup"
    fi

    # Markup if using ffmpeg
    useFFMPEG=N
    [ -z $(command -v ffmpeg) ] || useFFMPEG=Y

}

installDependencies() {

    # Sudo Access required
    rootRequired

    # Track if anything was installed
    installRequired=N

    # Check if all packages already installed
    if [ -z $(command -v curl) ] \
    || [ -z $(command -v crontab) ] \
    || [ -z $(command -v jq) ]; then

        # User Confirm
        installRequired=Y
        echo ""
        echo "The following packages will be installed on your device..."
        echo "    curl          - used for talking with the dailymotion api"
        echo "    cron          - used to schedule this script to run automatically"
        echo "    jq            - used to interpret the json formatted returns from dailymotion"
        echo ""
        promptYesNo "Are you happy to continue?"
        [ $? -eq $ec_Yes ] || exit

        # Install Required Packages
        sudo apt-get install curl cron jq || exit 1

    fi

    # Check if either avconv or ffmpeg is installed
    if [ -z $(command -v avconv) ] && [ -z $(command -v ffmpeg) ]; then

        # User Confirm
        installRequired=Y
        echo ""
        echo "Your system requires at least one of the following packages..."
        echo "    ffmpeg        - used for splitting videos to fit max video size"
        echo "    libav-tools   - used for splitting videos to fit max video size"
        echo "Your system may only support one of these, so both will be attempted..."
        promptYesNo "Are you happy to continue"
        [ $? -eq $ec_Yes ] || exit

        # Try install ffmpeg
        sudo apt-get install ffmpeg

        # Try install avconv if that failed
        if [ $? -ne $ec_Success ]; then
            printError "Failed to install ffmpeg.  Trying libav-tools instead..."
            sudo apt-get install libav-tools || exit 1
        fi

    fi

    # Check if youtube-dl is installed
    if ! [ -f $ytdl ]; then

        # User Confirm
        installRequired=Y
        echo ""
        echo "The following program will be downloaded to your device..."
        echo "    youtube-dl    - service for downloading youtube videos"
        echo "    source code:  $ytdlSource"
        promptYesNo "Are you happy to continue?"
        [ $? -eq $ec_Yes ] || exit

        # Install Youtube-dl
        sudo wget $ytdlSource --output-document $ytdl || exit 1
        sudo chmod a+rx $ytdl || exit 1

    fi

}

setRunProcedure() {

    # Error when called more than once
    if [ $optRunProcedure -gt 0 ]; then
        raiseError "Multiple procedures requested!  Please select only one.  See --help for more details"
    fi

    # Set procedure
    optRunProcedure=$1

}

inputArguments() {

    # enum for distinct command processing options
    co_mainProcedure=0
    co_editUrlsFile=1
    co_editPropFile=2
    co_editCronFile=3
    co_stopCronSchedule=4
    co_firstTimeSetup=5
    co_dailymotionLoginRevoke=6
    co_dailymotionLoginNew=7
    co_ChangeDailyMotionUsername=8
    co_ChangeDailyMotionScreenname=9
    co_uploadAvatarImage=10
    co_uploadCoverImage=11
    co_openPublishedFile=12
    co_watchExistingInstance=13
    co_killExistingInstance=14
    co_updateSourceCode=15
    co_showUploadsToday=16
    co_syncUploadsToday=17
    co_markAsDownloaded=18
    co_syncVideoDetails=19
    co_checkServerTimeOffset=20
    co_devTestCode=21

    # Set Default Argument Options
    optRunProcedure=$co_mainProcedure
    optDebug=N
    optSkipStartupChecks=N
    optUserRunUpload=N
    optKeepLogFile=N
    optCountOfUpload=
    optUploadSpecificVideoID=
    optIgnoreAllowance=N
    optAllowMultiInstances=N
    optUploadAvatarImage=
    optUploadBannerImage=
    optMarkDoneID=
    optSyncDailyMotionID=
    optUpdateGitBranch=

    # Loop Program's Input Agruments
    for i in $arguments; do
        [ -z "$i" ] && break
        case $i in
        -h|--help|-\?|\?)
            helpMenu
            ;;
        -d|--debug)
            optDebug=Y
            ;;

        # Main controls
        --keep-log-file)
            optKeepLogFile=Y
            ;;
        --count=*)
            optUserRunUpload=Y
            optCountOfUpload="${i#*=}"
            isNumeric $optCountOfUpload \
                || raiseError "--count=NUM must be numeric!"
            ;;
        --single-video=*)
            optUserRunUpload=Y
            optUploadSpecificVideoID="${i#*=}"
            ;;
        --ignore-allowance)
            optUserRunUpload=Y
            optIgnoreAllowance=Y
            ;;
        --multi-instance)
            optUserRunUpload=Y
            optAllowMultiInstances=Y
            ;;

        # Editing preferances
        --edit-urls)
            setRunProcedure $co_editUrlsFile
            optSkipStartupChecks=Y
            ;;
        --edit-prop)
            setRunProcedure $co_editPropFile
            optSkipStartupChecks=Y
            ;;

        --edit-schedule)
            setRunProcedure $co_editCronFile
            optSkipStartupChecks=Y
            ;;
        --stop-schedule)
            setRunProcedure $co_stopCronSchedule
            optSkipStartupChecks=Y
            ;;
        --first-time-setup)
            setRunProcedure $co_firstTimeSetup
            optSkipStartupChecks=Y
            ;;

        # Managing dailymotion account
        --revoke-access)
            setRunProcedure $co_dailymotionLoginRevoke
            optSkipStartupChecks=Y
            ;;
        --grant-access)
            setRunProcedure $co_dailymotionLoginNew
            ;;
        --change-username)
            setRunProcedure $co_ChangeDailyMotionUsername
            ;;
        --change-screenname)
            setRunProcedure $co_ChangeDailyMotionScreenname
            ;;
        --upload-avatar=*)
            setRunProcedure $co_uploadAvatarImage
            optUploadAvatarImage="${i#*=}"
            ;;
        --upload-banner=*)
            setRunProcedure $co_uploadCoverImage
            optUploadBannerImage="${i#*=}"
            ;;

        # Managing running instances
        --view-published)
            setRunProcedure $co_openPublishedFile
            ;;
        --watch-log-file)
            setRunProcedure $co_watchExistingInstance
            ;;
        --kill-existing)
            setRunProcedure $co_killExistingInstance
            ;;

        # Debugging commands
        --update)
            setRunProcedure $co_updateSourceCode
            optSkipStartupChecks=Y
            ;;
        --update=*)
            setRunProcedure $co_updateSourceCode
            optUpdateGitBranch="${i#*=}"
            optSkipStartupChecks=Y
            ;;
        --show-dm-uploads)
            setRunProcedure $co_showUploadsToday
            ;;
        --sync-dm-uploads)
            setRunProcedure $co_syncUploadsToday
            ;;
        --mark-done=*)
            setRunProcedure $co_markAsDownloaded
            optMarkDoneID="${i#*=}"
            ;;
        --sync-dm-id=*)
            setRunProcedure $co_syncVideoDetails
            optSyncDailyMotionID="${i#*=}"
            ;;
        --check-time-offset)
            setRunProcedure $co_checkServerTimeOffset
            ;;
        --dev-test-code)
            setRunProcedure $co_devTestCode
            ;;
        *)
            raiseError "Unknown argument: $i"
            ;;
        esac
    done

    # Print Current Arguments (debug info only)
    if [ $optDebug = Y ]; then
        echo "optDebug:                 " $optDebug
        echo "optRunProcedure:          " $optRunProcedure
        echo "optSkipStartupChecks:     " $optSkipStartupChecks
        echo "optUserRunUpload:         " $optUserRunUpload
        echo "optKeepLogFile:           " $optKeepLogFile
        echo "optCountOfUpload:         " $optCountOfUpload
        echo "optUploadSpecificVideoID: " $optUploadSpecificVideoID
        echo "optIgnoreAllowance:       " $optIgnoreAllowance
        echo "optAllowMultiInstances:   " $optAllowMultiInstances
        echo "optUploadAvatarImage:     " $optUploadAvatarImage
        echo "optUploadBannerImage:     " $optUploadBannerImage
        echo "optMarkDoneID:            " $optMarkDoneID
        echo "optSyncDailyMotionID:     " $optSyncDailyMotionID
        echo "optUpdateGitBranch:       " $optUpdateGitBranch
    fi
}

defaultProcedure() {

    # Standard run when not in interactive mode
    if ! [ -t 0 ]; then

        # Check if existing process running this script
        [ $optAllowMultiInstances = Y ] || exitOnExistingInstance
    
        # Run main procedure with logs saved
        main > "$logFile" 2>&1

        # If a download failed occured, alert user to attempt an update of youtube-dl
        howToUpdateIfDownloadFailureOccurred 1>&2

    else
        # Has user specified they want to do an upload?
        echo ""
        if [ $optUserRunUpload = Y ]; then

            # Check if existing process running this script
            [ $optAllowMultiInstances = Y ] || exitOnExistingInstance
        
            # Double check they want to run outside of schedule
            echo "Running this command will start an upload outside of your set schedule"
            echo "Try using the --edit-schedule command if you want to change when this code runs"
            promptYesNo "Are you sure you want to start uploading outside of your set schedule?"
            [ $? -eq $ec_Yes ] || exit

            # Start the main procedure
            main

        else

            # Has the first schedule run yet? (based on existance of log file)
            if [ -f "$logFile" ]; then
                watchExistingInstance
            else

                # Validate everything is setup
                echo "Validating your setup..."
                validateSetup

                # Tell the user everything has been setup
                echo ""
                if [ $setupValidated = Y ]; then
                    echo "Everything has now been setup!"
                    echo "Please wait for the first scheduled run to kick in before looking for results"
                    echo "You can review/change your scheduled time by using the command --edit-schedule"
                    echo ""
                    echo "Try using the --help command if you are looking for other options"
                else
                    raiseError "Validation failed!"
                fi
            fi
            exit
        fi
    fi

}

procedureSelection() {

    case $optRunProcedure in

        # Standard routine
        $co_mainProcedure)
            defaultProcedure
            ;;

        # Edit the urls File
        $co_editUrlsFile)
            editUrlsFile
            ;;

        # Edit the Properties File
        $co_editPropFile)
            editPropFile
            ;;

        # Edit the Cron job File
        $co_editCronFile)
            editCronFile
            ;;

        # Stop the Cron Scheduled Job
        $co_stopCronSchedule)
            stopCronSchedule
            ;;

        # First Time setup procedure
        $co_firstTimeSetup)
            firstTimeSetup
            ;;

        # Disable access to this api key
        $co_dailymotionLoginRevoke)
            rootRequired
            revokeDailyMotionAccess
            stopCronSchedule
            ;;

        # Reprompt dailymotion login
        $co_dailymotionLoginNew)
            dailyMotionReLogin
            ;;

        # Change the username on dailymotion
        $co_ChangeDailyMotionUsername)
            initializeDailyMotion
            dmChangeUserField "username"
            ;;

        # Change the screenname on dailymotion
        $co_ChangeDailyMotionScreenname)
            initializeDailyMotion
            dmChangeUserField "screenname"
            ;;

        # Upload image to channel avatar
        $co_uploadAvatarImage)
            uploadChannelArt "avatar" "$optUploadAvatarImage"
            ;;

        # Upload image to channel cover art
        $co_uploadCoverImage)
            uploadChannelArt "cover" "$optUploadBannerImage"
            ;;

        # Open the published csv file
        $co_openPublishedFile)
            tablePrintPublishedJson
            ;;

        # Watch the log file of an existing instance
        $co_watchExistingInstance)
            watchExistingInstance
            ;;

        # Kill an existing running instance
        $co_killExistingInstance)
            killExistingInstance
            ;;

        # Self updating code
        $co_updateSourceCode)
            updateSourceCode
            ;;

        # Query dailymotion to see what was done today
        $co_showUploadsToday)
            initializeDailyMotion
            echoUploadsToday
            ;;

        # Dump the results of the dailymotin query (above) to the local tracking file
        $co_syncUploadsToday)
            initializeDailyMotion
            rebuildAllowanceFile
            ;;

        # Update the archive give to indicate which videos are already downloaded
        $co_markAsDownloaded)
            markAsDownloaded
            ;;

        # Sync an already uploaded video with the details on youtube
        $co_syncVideoDetails)
            syncVideoDetails
            ;;

        # Check the time difference between local machine and dailymotion's servers
        $co_checkServerTimeOffset)
            initializeDailyMotion
            checkServerTimeOffset
            ;;

        # Run code in the test procedure (DEV ONLY)
        $co_devTestCode)
            testCodeDevONLY
            ;;

        # Unknown enum setting
        *)
            raiseError "Unknown enum run procedure number $optRunProcedure"
            ;;

    esac
}

helpMenu() {

    # Prepare wrap settings (done here for speed improvement)
    prefixLength=26
    prefixSpaces="$(for ((i=1; i<=$prefixLength; i++)); do echo -n " "; done)"
    consoleColumns=$(tput cols)
    wrapLength=$((consoleColumns-prefixLength))
    doWrap=N
    [ $wrapLength -gt 20 ] && doWrap=Y

    # Print basic header info
    echo "Usage:   " $scriptFile" [OPTION]"
    echo "Version: " $scriptVersionNo
    echo ""
    echo "Downloads a given set of YouTube videos on the matching .urls file and uploads them to a dailymotion.com account." | fold -s --width=$consoleColumns
    echo "Recommended to schedule run every 24 hours (see --edit-schedule)" | fold -s --width=$consoleColumns


    # Print options
    echo ""
    echo "OPTIONS - main controls"
    wrapHelpColumn "  -h, --help, -?, ?       " "Prints this help menu and quits"
    wrapHelpColumn "  -d, --debug             " "Prints additional info while running"
    wrapHelpColumn "      --keep-log-file     " "Saves a backup of the .log file to the output directory after each run"
    wrapHelpColumn "      --count=NUM         " "Only upload the specified number then stop (used for testing 1 at a time)"
    wrapHelpColumn "      --single-video=ID   " "Only upload the specified youtube video ID then stop (can be any valid video id, does not have to exist on your .urls file)"
    #wrapHelpColumn "      --ignore-allowance  " "Ignore upload allowance restrictions (for testing purposes ONLY)"
    #wrapHelpColumn "      --multi-instance    " "TESTING ONLY.  Allow a second instance to be run while another is still going"

    echo ""
    echo "  OPTIONS - for editing your preferences"
    wrapHelpColumn "      --edit-urls         " "Bring up the editor for the file which holds the urls of the playlists/channels to download"
    wrapHelpColumn "      --edit-prop         " "Bring up the editor for the properties file to change preferences on how the video is published"
    wrapHelpColumn "      --edit-schedule     " "Bring up the editor for the cron job which schedules this script to run.  Requires root"
    wrapHelpColumn "      --stop-schedule     " "Completely stop the schedule from running this script automatically.  Requires root"
    wrapHelpColumn "      --first-time-setup  " "Triggers automatically on first run (WARNING - running this will reset your login and preferences!).  This is run by default when nothing has been setup yet.  Requires root"

    echo ""
    echo "  OPTIONS - for managing your dailymotion account"
    wrapHelpColumn "      --revoke-access     " "Revoke all access to the given dailymotion access (if you want to stop using this).  Requires root"
    wrapHelpColumn "      --grant-access      " "Trigger prompt for dailymotion login details.  WARNING this will remove any existing saved login"
    wrapHelpColumn "      --change-username   " "Provides access to change your dailymotion username account for the channel url (may not work on all accounts)"
    wrapHelpColumn "      --change-screenname " "Provides access to change your dailymotion screenname that is displayed on your home page"
    wrapHelpColumn "      --upload-avatar=IMG " "Set the IMG to a image file location that you want uploaded as the accounts Profile Avatar"
    wrapHelpColumn "      --upload-banner=IMG " "Set the IMG to a image file location that you want uploaded as the accounts Cover Banner"

    echo ""
    echo "  OPTIONS - for managing current/previous running instance"
    wrapHelpColumn "      --view-published    " "View a list of all published videos. Press Q to quit, use up/downs to navigate. (Alternatively an Excel csv file is also available in the main folder)"
    wrapHelpColumn "      --watch-log-file    " "Real time log view of an existing (or previously) run instance.  Press Ctrl+C to escape.  This is run by default when first-time-setup is complete and no other command specified"
    wrapHelpColumn "      --kill-existing     " "DEV ONLY.  Used to kill an existing running instance of this script"

    echo ""
    echo "  OPTIONS - for debugging issues"
    wrapHelpColumn "      --update            " "Download the latest release of this script and replace the current version with it.  Requires root"
    #wrapHelpColumn "      --update[=BRANCH]   " "Download the latest release of this script (from the specified git branch) and replace the current version with it.  Requires root"
    wrapHelpColumn "      --show-dm-uploads   " "Query with dailymotion what videos where uploaded in last 24 hours, and compare to local tracking file (for debugging why limits might have exceeded)"
    wrapHelpColumn "      --sync-dm-uploads   " "Same as above, but outputs the dailymotion results to the local allowance tracking file for use during uploads.  Use this if you manually uploaded a video and need this script to account for it when uploading more.  DO NOT USE if you are maintaining multiple dailymotion accounts on the same internet connection."
    wrapHelpColumn "      --mark-done=ID      " "Mark the given youtube [ID] as downloaded"
    wrapHelpColumn "      --mark-done=ALL     " "Mark all videos in the .urls file as downloaed (i.e. only upload new videos)"
    wrapHelpColumn "      --mark-done=SYNC    " "Mark all videos in the published.json file as downloaded (e.g. to fix problems that might happen)"
    wrapHelpColumn "      --sync-dm-id=ID     " "Sync the current details of the given dailymotion video [ID] with the original youtube video"
    #wrapHelpColumn "      --check-time-offset " "(debugging purposes). Compare the local time to the time on dailymotion servers.  Useful you are exceeding allowances and might be due to clock setting differences"
    #wrapHelpColumn "      --dev-test-code     " "DEV ONLY. Run whatever code is in the test procedure"
    echo ""

    exit
}

wrapHelpColumn() {
    prefix="$1"
    suffix="$2"
    if [ $doWrap = Y ]; then
        suffixWrap=$(fold --spaces --width=$wrapLength <<< "$suffix")
        echo "$prefix$(head -1 <<< "$suffixWrap")"
        if [ $(wc -l <<< "$suffixWrap") -gt 1 ]; then
            echo "$(tail -n +2 <<< "$suffixWrap" | sed -e "s/^/$prefixSpaces/")"
        fi
    else
        echo "$prefix$suffix"
    fi
}

getExistingInstance() {

    # Info on this process
    #prevProcessId=$!
    thisProcessId=$$

    # Check for existing running instance
    existingProcessId=$(pgrep --full --oldest "/bin/bash.*$scriptFile")
    if [ $existingProcessId -ne $thisProcessId ]; then
        existingProcessStart=$(ps --no-headers --format lstart --pid $existingProcessId)
    else
        existingProcessId=0
        existingProcessStart=
    fi

    # Info on Locked process
    lockedProccessId=0
    [ -f "$instanceLockFile" ] && \
        lockedProccessId=$(head -1 "$instanceLockFile")

}

printExistingInstanceInfo() {
    echo -n "$scriptFile has already been running since $existingProcessStart (pid: ${existingProcessId})"
}

exitOnExistingInstance() {

    # Info on existing instance
    getExistingInstance

    # If it's the same as the locked instance, then exit
    if [ $lockedProccessId -gt 0 ] && [ $lockedProccessId -eq $existingProcessId ]; then
        raiseError $(printExistingInstanceInfo)
    fi

    # Record this process id on the lock file
    echo $thisProcessId > "$instanceLockFile"

}

releaseInstance() {
    [ -f "$instanceLockFile" ] && rm "$instanceLockFile"
}

killExistingInstance() {

    # Info on existing instance
    getExistingInstance

    # Exit if no instance
    if [ $existingProcessId -eq 0 ]; then
        echo "No existing instance found!"
        exit 0
    fi

    # Are you sure?
    promptYesNo "Kill the existing instance running since $existingProcessStart, pid: ${existingProcessId}?"
    [ $? -eq $ec_Yes ] || exit

    # Kill the existing instance
    kill $existingProcessId
    
    # Copy the log file
    if [ $existingProcessId -eq $lockedProccessId ]; then
        loadPropertiesFile
        [ -z "$processingDirectoryFull" ] || outputDir=$processingDirectoryFull
        logArchiveDir="$outputDir"/$keepLogsDir/
        if [ -d "$logArchiveDir" ]; then 
            logArchive="killed_$logArchive"
            cp "$logFile" "$logArchiveDir/$logArchive"
        fi
    else
        # Info if didn't match the lock file
        echo ""
        echo "Note that the killed process did not match the locked process id $lockedProccessId"
        echo "You may need to run the kill command again"
    fi

}

watchExistingInstance() {

    # Error if no log file found
    [ -f "$logFile" ] || raiseError "Log file does not exist!"

    # Info on existing instance
    getExistingInstance

    # Print gap
    echo ""

    # Conditions to follow the log file
    if [ $existingProcessId -gt 0 ] && [ $existingProcessId -eq $lockedProccessId ]; then

        # Inform user of existing process info
        printExistingInstanceInfo
        echo ""
        promptYesNo "Would you like to watch the log of the running instance?"
        [ $? -eq $ec_Yes ] || exit
        echo ""

        # Check if process is still running
        if ps --pid $lockedProccessId > /dev/null ; then

            # Follow the log till process ends
            tail --follow --pid=$lockedProccessId --lines=+1 "$logFile"

            # Confirm complete
            echo ""
            echo ""
            echo "Stopped watching the log because the process ended"

            # Exit
            return 0

        else

            # Print info if user took too long to respond
            echo "Process already stopped!"
            echo ""

        fi
    fi

    # Inform user there is nothing running
    echo "There is no existing instance of this script running!"
    promptYesNo "Would you like to display the log from the last ran instance?"
    [ $? -eq $ec_Yes ] || exit

    # Else just show the last log file
    tail --lines=+1 "$logFile"

}

main() {

    mainProcedureActivated=Y

    # Record script Version
    echo "$scriptDir/$scriptFile - version: $scriptVersionNo"
    echo ""

    # Record start time
    mainStartTime=$(date +%s)
    echo "Start date time:                " $(date -d @$mainStartTime)

    # Check required files exist
    [ -f "$urlsFile" ] || raiseError "urls file not found! $urlsFile"

    # Initial Variables
    startStatistics
    
    # Determine when the next 24 hour upload period begins
    queryVideoDuration=0
    oldestVideoThisHour=0
    oldestVideoThisDay=0
    [ -f "$allowanceFile" ] && dmGetAllowance --do-not-print
    uploadWindowStart=$mainStartTime
    if [ $oldestVideoThisHour -gt 0 ]; then
        uploadWindowStart=$((oldestVideoThisHour-300))
    else
        if [ $oldestVideoThisDay -gt 0 ]; then
            uploadWindowStart=$((oldestVideoThisDay+dmDurationAllowanceExpiry))
        fi
    fi
    uploadWindowEnd=$((uploadWindowStart+dmDurationAllowanceExpiry))
    echo "Upload window opens at:         " $(date -d @$uploadWindowStart)
    echo "Upload window closes at:        " $(date -d @$uploadWindowEnd)

    # Determine time to quit (before next schedule starts)
    dmUploadQuitingTime=$((mainStartTime+dmDurationAllowanceExpiry-300)) # 5 minute tolerance for startup time
    echo "Quit time before next schedule: " $(date -d @$dmUploadQuitingTime)
    echo ""

    # Quit when upload window doesn't open till within the set time of the next schedule
    if [ $uploadWindowStart -gt $((dmUploadQuitingTime-quitWhenUploadWindowIsWithin)) ]; then
        echo "Upload window does not start till close to the next scheduled run"
        echo "Quitting this run, and let the next schedule pick up the videos for processing"
        exitRoutine
    fi
    
    # Wait until nearer the upload window before starting
    earliestStartTime=$((uploadWindowStart-waitTimeBeforeDownloading))
    waitForWindowStart=$((earliestStartTime-$(date +%s)))
    if [ $waitForWindowStart -gt 0 ]; then
        echo "Upload window not open yet.  Waiting till "$(date +%X -d @$earliestStartTime)" before beginning ..."
        [ -t 0 ] && echo "(Or press Ctrl+C to quit instead)"
        sleep $waitForWindowStart
        echo ""
    fi
    
    # Restart start time for more accurate statistics
    mainStartTime=$(date +%s)

    # Get connected to dailymotion
    initializeDailyMotion

    # Move to output directory
    if [ -z "$processingDirectoryFull" ]; then
        [ -d "$outputDir" ] || mkdir "$outputDir"
    else
        outputDir=$processingDirectoryFull
    fi
    cd "$outputDir"

    # Single video request
    if ! [ -z "$optUploadSpecificVideoID" ]; then
        videoId=$optUploadSpecificVideoID
        downloadVideo || exitRoutine
        processExistingJsons
        exitRoutine
    fi

    # process existing videos not uploaded from previous session
    processExistingJsons

    # Process new downloads from youtube
    processNewDownloads

    # Run the exit routine
    exitRoutine
}

exitRoutine() {

    # Exit if not run by main procedure
    [ -z $mainProcedureActivated ] && exit
    
    # Clean up actions after uploads
    if [ $totalVideosUploaded -gt 0 ]; then
    
        # Clear down the video cache of upload videos
        clearVideoCacheFile

        # Wait for remaining videos to be published
        queryVideoDuration=0
        dmGetAllowance --do-not-print
        if [ $unpublishedVideosExist = Y ]; then
            checkTill=$dmUploadQuitingTime
            checkOnPublishingVideos
        fi

        # Print info on what was done
        printStatistics
    fi
    
    # Release the lock file
    releaseInstance

    # Backup important files
    if [ -d "$processingDirectoryFull" ]; then
        bkuDir="$processingDirectoryFull"/$backupDir/
        [ -d "$bkuDir" ] || mkdir "$bkuDir"
        cp --force "$publishedUploadsFile" "$bkuDir"
        cp --force "$publishedUploadsFileCSV" "$bkuDir"
        cp --force "$propertiesFile" "$bkuDir"
        cp --force "$urlsFile" "$bkuDir"
        cp --force "$archiveFile" "$bkuDir"
    fi

    # Record finish time
    echo ""
    echo finished $(date +"%F %T")

    # Archive the log
    if ! [ -t 0 ] && [ $optKeepLogFile = Y ] && [ -d "$outputDir" ]; then
        logArchiveDir="$outputDir"/$keepLogsDir/
        [ -d "$logArchiveDir" ] || mkdir "$logArchiveDir"
        cp "$logFile" "$logArchiveDir/$logArchive"
    fi

    # Ensure program stops from wherever this is called from
    exit
}

startStatistics() {

    # Start Statistics
    totalVideosRemaining=0
    totalVideosUploaded=0
    totalVideosSkipped=0
    totalDurationUploaded=0
    totalDurationSkipped=0

}

recordSkipStats() {
    ((totalVideosSkipped++))
    ((totalDurationSkipped+=videoDuration))
}

printStatistics() {
    echo "********************************************************************"
    echo "**** Upload statistics for session on $(date +"%F") *******************"
    echo "********************************************************************"
    echo "********************************************************************"
    echo "**** Remaining videos to be uploaded:  " $((totalVideosRemaining-totalVideosUploaded))
    echo "**** Videos uploaded this session:     " $totalVideosUploaded
    echo "**** Total duration uploaded:          " $(date +%T -u -d @$totalDurationUploaded) "("$totalDurationUploaded" seconds)"
    echo "**** Videos skipped:                   " $totalVideosSkipped
    echo "**** Total duration of skipped videos: " $((totalDurationSkipped/60/60))"h "$(date +"%Mm %Ss" -u -d @$totalDurationSkipped) "("$totalDurationSkipped" seconds)"
    echo "**** Total time taken:                 " $(date +"%Hh %Mm %Ss" -d "-$mainStartTime seconds")
    echo "********************************************************************"
}

initialiseVariables() {

    # Procedure to clear all the variables between video uploads (to ensure the next loop doesn't use info from previous)
    cachedInfo=
    cachedInfoArr=
    cachedUploadDate=
    cachedVideoDuration=
    checkTill=
    checkTime=
    confirmVideoId=
    currentTime=
    dailyLimitWaitTill=
    delayedDays=
    delayedUntil=
    dmCreatedTime=
    dmDescrTemplateNew=
    dmDuration=
    dmEditedVideoId=
    dmEncodingPC=
    dmErrorReason=
    dmExplicit=
    dmIdCheck=
    dmPostedUrl=
    dmPublishedVideoId=
    dmPublishingPC=
    dmServerResponse=
    dmStatus=
    dmUploadUrl=
    dmVideoDescr=
    dmVideoId=
    dmVideoTitle=
    dmVideoUrl=
    downloadError=
    durationLimitWaitTill=
    durationUploadWindow=
    durationUploadWindowMAX=
    fieldContext=
    fieldName=
    hashTags=
    hourlyUploadWindow=
    i=
    jsonFound=
    jsonName=
    latestUploadTime=
    maxWaitTill=
    minimumWaitTill=
    minSplitDuration=
    mirrorDate=
    newDurationCheck=
    newFileContent=
    oldestVideoThisDay=
    oldestVideoThisHour=
    #origVideoSplits=
    prevDmDescr=
    prevDmId=
    prevDmNextId=
    prevDmStatus=
    previousSplit=
    prevPart=
    prevPublishedPart=
    printAllowances=
    publishWaitTill=
    queryVideoDuration=
    #rec=
    recArr=
    #recs=
    recsInLastDay=
    remainingDailyVideos=
    #remainingDailyVideosMAX=
    remainingDuration=
    #remainingDurationMAX=
    remainingDurationSoon=
    remainingVideos=
    resortFile=
    returnCode=
    sleepTill=
    sleepTime=
    splitFilename=
    splitJson=
    splitTitle=
    splitUploadsDone=
    targetMessage=
    targetTime=
    timeTillQuit=
    timeTillWindowEnds=
    tmpJson=
    tmpSplitDir=
    trueSplitDuration=
    trueSplitDurationSTR=
    #unpublishedVideosExist=
    uploadDur=
    uploadFilePath=
    uploadId=
    uploadLine=
    uploadsAfter=
    #uploadsBefore=
    uploadStatus=
    uploadTime=
    VideoBlockingUpload=
    videoDate=
    videoDateStr=
    videoDuration=
    videoExt=
    videoFields=
    videoFilename=
    videoFilePath=
    videoFileSize=
    videoFileSizeSplit=
    videoId=
    #videoJson=
    videoLimitWaitTill=
    videoPart=
    videoSplits=
    videoThumbnail=
    videoTitle=
    vj=
    vjVideoId=
    waitInfoPrinted=
    waitingForType=
    waitingTime=
    youtubeChannel=
    youtubeVideoDescr=
    youtubeVideoLink=
    youtubeVideoTags=
    youtubeVideoTagsList=
    youtubeVideoUploadDate=
    #ytdlDownloadErrorOccured=
    ytVideoId=

}

getVideoDuration() {

    # Defaults
    cachedInfo=
    cachedVideoDuration=0
    cachedUploadDate=
    videoDuration=0

    # Query Cache file for video ID
    if [ -f "$videoCacheFile" ]; then
        cachedInfo=$(grep --max-count=1 "^$videoId " "$videoCacheFile")
    fi

    # Take duration from cache
    if ! [ -z "$cachedInfo" ]; then
        cachedInfoArr=(${cachedInfo})
        cachedVideoDuration=${cachedInfoArr[1]}
        cachedUploadDate=${cachedInfoArr[2]}

        # Use the cached duration if it does not meet the conditions for a live stream that needs checked for trimming
        if [ -z "$cachedUploadDate" ] \
        || [ $cachedVideoDuration -lt $delayDownloadDuration ] \
        || [ $cachedUploadDate -lt $delayDownloadsAfter ]; then
            videoDuration=$cachedVideoDuration
            return $ec_Success
        fi
    fi

    # Query youtube-dl for video duration
    tmpJson=$(mktemp)
    logAction "Querying youtube-dl for video id $videoId"
    $ytdl --dump-json -- $videoId > $tmpJson
    if [ $? -ne $ec_Success ]; then
        rm $tmpJson
        ytdlDownloadErrorOccured=Y
        pause "Failed to download.  Press enter to continue, or Ctrl+C to quit..."
        recordSkipStats
        return $ec_ContinueNext
    fi
    videoDuration=$(queryJson "duration" "$tmpJson") || exit 1
    videoDateStr=$(queryJson "upload_date" "$tmpJson") || exit 1
    videoDate=$(date +%s -d "$videoDateStr")
    rm $tmpJson

    # Cache duration for next time
    [ -z "$cachedInfo" ] && echo $videoId $videoDuration $videoDate >> "$videoCacheFile"

    # Apply Live Stream Check Delay Rules (as per properties file)
    if [ $videoDate -gt $delayDownloadsAfter ] && [ $videoDuration -gt $delayDownloadDuration ]; then

        # Check if a trim has occurred since last cache
        if ! [ $videoDuration -lt $cachedVideoDuration ]; then

            # Mark up that video has to be delayed
            delayedUntil=$(date +%s -d "$videoDateStr + $delayedVideosWillBeUploadedAfter")
            delayedDays=$(((delayedUntil-$(date +%s))/86400+1))
            echo "Video duration is "$(date +%T -u -d @$videoDuration)". Delaying for "$delayedDays" days."
            echo "(Due to property settings on delayDownloadIfVideoIsLongerThan and delayedVideosWillBeUploadedAfter)"

            # Skip to next video
            recordSkipStats
            return $ec_ContinueNext
        fi
    fi

}

clearVideoCacheFile() {

    # Get a list of uploaded ids
    tmpUploadedIDsFile=$(mktemp)
    jq --raw-output \
        '.youtubeId' \
        "$publishedUploadsFile" \
        > $tmpUploadedIDsFile

    # Compare to ids from cache file
    tmpNewCacheFile=$(mktemp)
    grep --fixed-strings \
        --invert-match \
        --file $tmpUploadedIDsFile \
        "$videoCacheFile" \
        > $tmpNewCacheFile

    # Only keep what hasn't been uploaded
    cp $tmpNewCacheFile "$videoCacheFile"
    rm --force $tmpNewCacheFile
    rm --force $tmpUploadedIDsFile

}

getYouTubeInfoFromJson() {

    # json file required
    [ -f "$videoJson" ] || raiseError "json file does not exist!? $videoJson"

    # Get Video metadata
    youtubeVideoUploadDate=$(queryJson "upload_date" "$videoJson") || exit 1
    youtubeChannel=$(queryJson "uploader_url" "$videoJson") || exit 1
    ytVideoId=$(queryJson "id" "$videoJson") || exit 1
    youtubeVideoDescr=$(queryJson "description" "$videoJson") || exit 1
    youtubeVideoLink=$(queryJson "webpage_url" "$videoJson") || exit 1
    videoDuration=$(queryJson "duration" "$videoJson") || exit 1
    videoThumbnail=$(queryJson "thumbnail" "$videoJson") || exit 1
    videoExt=$(queryJson "ext" "$videoJson") || exit 1
    videoTitle=$(queryJson "fulltitle" "$videoJson") || exit 1
    videoPart=$(queryJson "splitPart" "$videoJson") || exit 1
    youtubeVideoTags=$(queryJson "tags" "$videoJson") || exit 1
    youtubeVideoTags=${youtubeVideoTags:1:-1} #remove square brackets
    youtubeVideoTags=${youtubeVideoTags//\"}  #remove quotes
    jsonName=$(basename "$videoJson")
    #videoFilename=${jsonName%.*}
    videoFilename=${jsonName//.$ytdlInfoExt/}
    videoFilePath=$videoFilename.$videoExt
    #thumbnailFilePath="$videoFilename.${videoThumbnail##.*}"

    # Format date
    youtubeVideoUploadDate=${youtubeVideoUploadDate:0:4}-${youtubeVideoUploadDate:4:2}-${youtubeVideoUploadDate:6:2}

    # Extract Hash Tags from description
    hashTags=$(grep --perl-regexp \
        --only-matching \
        "#\K[^#]*\b" \
        <<< "$youtubeVideoDescr"
        )
    hashTags=${hashTags//$'\n'/,}
    if ! [ -z "$hashTags" ]; then
        if [ -z "$youtubeVideoTags" ]; then
            youtubeVideoTags=$hashTags
        else
            youtubeVideoTags=$hashTags","$youtubeVideoTags
        fi
    fi

    # Expand description from template
    youtubeVideoDescr=${youtubeVideoDescr//$'\n'/\\\n}
    dmDescrTemplateNew=${uploadVideoDescrTEMPLATE//$'\n'/\\\\n}
    dmVideoDescr="$(eval echo $dmDescrTemplateNew)"
    dmVideoDescr="${dmVideoDescr//\\n/$'\n'}"

    # Append Default tags
    if ! [ -z "$uploadVideoAppendedTags" ]; then
        if [ -z "$youtubeVideoTags" ]; then
            youtubeVideoTags=$uploadVideoAppendedTags
        else
            youtubeVideoTags+=","$uploadVideoAppendedTags
        fi
    fi

    # Prefix youtube id as tag
    if [ -z "$youtubeVideoTags" ]; then
        youtubeVideoTags=$ytVideoId
    else
        youtubeVideoTags=$ytVideoId","$youtubeVideoTags
    fi

    # Max Description/Title Length
    dmVideoDescr=${dmVideoDescr:0:$dmMaxDescription}
    videoTitle=${videoTitle:0:$dmMaxTitleLength}

    # Max Tags
    # 1) replace , with new line 2) remove duplicates 3) top 150 4) put comma's back
    youtubeVideoTagsList=$(tr , "\n" \
        <<< $youtubeVideoTags \
        | awk '!a[$0]++' \
        | head -$dmMaxTags
        )
    youtubeVideoTags=${youtubeVideoTagsList//$'\n'/,}

    # Show all details on debug
    if [ $optDebug = Y ]; then
        echo "videoTitle:  " $videoTitle
        echo "Filename:    " $videoFilename
        echo "Upload Date: " $youtubeVideoUploadDate
        echo "Channel:     " $youtubeChannel
        echo "Video ID:    " $ytVideoId
        echo "Video Link:  " $youtubeVideoLink
        echo "Duration:    " $videoDuration
        echo "Video Pic:   " $videoThumbnail
        echo "Video File:  " $videoFilePath
        echo "Tags:        " $youtubeVideoTags
        echo ""
        echo "$dmVideoDescr"
    fi

}

processExistingJsons() {

    preExistingVideos=0
    for videoJson in ./*.$ytdlInfoExt ; do
        [ -f "$videoJson" ] || break

        # Initialise Variables
        initialiseVariables

        # Add on to remaining videos (as would not have been counted previously)
        ((preExistingVideos++))

        # Get Video Info
        getYouTubeInfoFromJson

        # Run the prep before upload
        videoId=$ytVideoId
        prepareForUpload
        returnCode=$?
        case $returnCode in
            $ec_ContinueNext) continue ;;
            $ec_BreakLoop) break ;;
            $ec_Success) ;;
            *) exit $ec_Error ;;
        esac

        # Print video title
        echo "Processing: $videoTitle"

        # Process any required video splitting
        splitVideoRoutine
        returnCode=$?
        case $returnCode in
            $ec_ContinueNext) continue ;;
            $ec_BreakLoop) break ;;
            $ec_Success) ;;
            *) exit $ec_Error ;;
        esac

        # Ready for upload
        uploadToDailyMotion

        # Finish marker
        echo "********************************************************************"

    done

}

getFullListOfVideos() {

    # Get list of all video ids from the given urls file
    $ytdl \
        --skip-download \
        --dump-json \
        --flat-playlist \
        ${youtubePlaylistReverseOpt:+ --playlist-reverse} \
        --batch-file "$urlsFile"
    # (This has been tested that to show that it excludes active live streams)

    # Try again on error (sometimes there are connection issues)
    if [ $? -ne $ec_Success ]; then
        if ! [ "$secondAttempt" = "Y" ]; then
            printError "Failed to get video list.  Trying one more time..."
            secondAttempt=Y
            getFullListOfVideos
        else
            raiseError "Failed to get video list"
        fi
    fi

}

formatFullListOfVideos() {

    # Format json from youtube-dl to just show the video id
    getFullListOfVideos | jq --raw-output \
        '"\(.ie_key|ascii_downcase) \(.id)"' #" \(.title)"

}

resetVideoSearchTimeout() {

    # Add timeout to current time
    stopVideoDurationSearch=$(($(date +%s)+timeoutVideoDurationSearch))

}

processNewDownloads() {

    # Store all video ids from given youtube playlists/channels/videos
    echo "Connecting to youtube-dl server for video list..."
    formatFullListOfVideos > "$videoListFile"

    # Compare with the done file to see what's new
    if [ -f "$archiveFile" ]; then
        echo "Checking for new videos..."
        videoListFileTmp=$(mktemp)
        grep --fixed-strings \
            --invert-match \
            --line-regexp \
            --file "$archiveFile" \
            "$videoListFile" \
            > $videoListFileTmp
        cp $videoListFileTmp "$videoListFile"
        rm --force $videoListFileTmp
        totalVideosRemaining=$((totalVideosRemaining+$(wc -l < "$videoListFile")))
        echo "Total videos remaining in all url playlists:" $totalVideosRemaining
        ((totalVideosRemaining+=preExistingVideos)) #correct counter
    fi

    # Timeout for how long to spend search searching for video that fits upload allowance
    resetVideoSearchTimeout

    # Download new videos
    readarray recs < "$videoListFile"
    for rec in "${recs[@]}"; do

        # Initialise Variables
        initialiseVariables

        # Get video Id from line in file
        recArr=(${rec})
        videoId=${recArr[1]}

        # Skip "0" ids (happens when single video url provided)
        [ "$videoId" = "0" ] && continue

        # Quit if spent too much time not uploading anything (only just for video duration that will fit)
        if [ $(date +%s) -gt $stopVideoDurationSearch ]; then
            echo "Cannot find video to fit remaining upload allowance within specified timeout period (i.e durationAllowanceSearchTimeout)"
            break
        fi

        # Prep for the upload (check upload limits etc)
        prepareForUpload
        returnCode=$?
        case $returnCode in
            $ec_ContinueNext) continue ;;
            $ec_BreakLoop) break ;;
            $ec_Success) ;;
            *) exit $ec_Error ;;
        esac

        # Download this youtube video id
        downloadVideo
        returnCode=$?
        case $returnCode in
            $ec_ContinueNext) continue ;;
            $ec_BreakLoop) break ;;
            $ec_Success) ;;
            *) exit $ec_Error ;;
        esac

        # Get Video Info
        getYouTubeInfoFromJson

        # Print video title
        echo "Processing: $videoTitle"

        # Process any required video splitting
        splitVideoRoutine
        returnCode=$?
        case $returnCode in
            $ec_ContinueNext) continue ;;
            $ec_BreakLoop) break ;;
            $ec_Success) ;;
            *) exit $ec_Error ;;
        esac

        # Upload to Daily Motion
        uploadToDailyMotion

        # Restart timeout for duration allowance video search
        resetVideoSearchTimeout

        # Finish marker
        echo "********************************************************************"

    done
}

downloadVideo() {

    # Wait 2 hours before the required time before uploading
    waitForUploadAllowance $waitTimeBeforeDownloading "before downloading"

    # Download this youtube video id
    downloadError=N
    logAction "Downloading YouTube video"
    $ytdl --output "%(title)s.%(ext)s" \
        --format best \
        --write-info-json \
        --no-progress \
        --download-archive "$archiveFile" \
        -- $videoId
    if [ $? -ne $ec_Success ]; then
        ytdlDownloadErrorOccured=Y
        downloadError=Y
    fi

    # Confirm ID (if url given)
    confirmVideoId=$($ytdl --get-id -- $videoId)

    # Find the downloaded json file
    jsonFound=N
    for vj in ./*.$ytdlInfoExt; do
        [ -f "$vj" ] || break
        vjVideoId=$(queryJson "id" "$vj") || exit 1
        if [ "$vjVideoId" = "$confirmVideoId" ]; then
            jsonFound=Y
            videoJson=$vj
            break
        fi
    done

    # Error Processing
    if [ $downloadError = Y ]; then

        # Delete any downloaded files
        if [ $jsonFound = Y ]; then
            videoExt=$(queryJson "ext" "$videoJson") || exit 1
            jsonName=$(basename "$videoJson")
            videoFilename=${jsonName//.$ytdlInfoExt/}
            videoFilePath=$videoFilename.$videoExt
            rm --force "./$videoJson"
            rm --force "./${videoFilePath}.part"
            rm --force "./$videoFilePath"
        fi

        # Markup Error
        printError "Failed to download video id" $videoId
        pause "Press enter to continue, or Ctrl+C to quit..."
        echo ""
        recordSkipStats
        return $ec_ContinueNext
    fi

    # Error if no json file
    if [ $jsonFound = N ]; then
        echo "json file not found after youtube download!?.  Skipping..."
        recordSkipStats
        return $ec_ContinueNext
    fi

}

howToUpdateIfDownloadFailureOccurred() {

    # Called outside of the log so as it prints to the mailer
    if [ $ytdlDownloadErrorOccured = Y ]; then
        echo "There was at least one video that failed to download!  See the log for more details (--watch-log-file)"
        echo "If this error persists then you should attempt to update the youtube-dl service using the following command:"
        echo "    sudo $ytdl --update"
        echo ""
        echo "Alternatively you could check for a newer version of this script with the following command:"
        echo "    $scriptFile --edit-urls"
    fi

}

markAsDownloaded() {

    # Backup existing archive file
    [ -f "$archiveFile" ] && cp "$archiveFile" "$archiveFile.bku"

    # Requested command?
    case "$optMarkDoneID" in
        "ALL")
            echo "Marking all videos in .url file as downloaded..."
            formatFullListOfVideos > "$archiveFile"
            ;;
        "SYNC")
            echo "Syncing with uploads .json file"
            jq --raw-output \
                '"youtube \(.youtubeId)"' \
                "$publishedUploadsFile" \
                > "$archiveFile"
            ;;
        *)
            echo "validating id/url"...
            confirmVideoId=$($ytdl --get-id -- $optMarkDoneID)
            if [ $? -ne $ec_Success ]; then
                promptYesNo "Could not validate video ID!  Are you sure you want to mark this has done?"
                [ $? -eq $ec_Yes ] || raiseError "Cancelled!"
                confirmVideoId=$optMarkDoneID
            fi
            [ -z "$confirmVideoId" ] && raiseError "Invalid ID/URL! $optMarkDoneID"
            echo "youtube $confirmVideoId" >> "$archiveFile"
            ;;
    esac
    echo "done"

}

splitVideoRoutine() {

    # Ensure file exists
    if ! [ -f "$videoFilePath" ]; then
        printError "Video File does not exist!? $videoFilePath"
        return $ec_ContinueNext
    fi

    # Recalculate the split size encase video was was trimmed after duration was cached
    if [ $videoSplits -gt 1 ]; then
        videoSplits=0
        if [ $dmMaxVideoDuration -gt 0 ] && [ $videoDuration -gt $dmMaxVideoDuration ]; then
            videoSplits=$((videoDuration/dmMaxVideoDuration+1))
        fi
    fi

    # Is split required for file size
    if [ $videoSplits -le 1 ]; then
        videoFileSize=($(du --bytes "$videoFilePath"))
        videoFileSize=${videoFileSize[0]}
        if [ $dmMaxVideoSize -gt 0 ] && [ $videoFileSize -gt $dmMaxVideoSizeTolerance ]; then
            echo "Video file size is too big ($videoFileSize)"

            # Estimate size after existing duration split (if any)
            [ $videoSplits -le 1 ] && videoSplits=2
            videoFileSizeSplit=$((videoFileSize/videoSplits))
            echo "Testing split size of $videoSplits ($videoFileSizeSplit)..."

            # Adjust split size to keep under max video size
            while [ $videoFileSizeSplit -gt $dmMaxVideoSizeTolerance ]; do
                ((videoSplits++))
                videoFileSizeSplit=$((videoFileSize/videoSplits))
                echo "Testing split size of $videoSplits ($videoFileSizeSplit)..."
            done

            echo "Contining with $videoSplits video splits..."
        fi
    fi

    # Process any splits
    if [ $videoSplits -gt 1 ]; then

        # Make temporary directory to hold json files with split info
        tmpSplitDir=$(mktemp -d)

        # Work out Split Size
        minSplitDuration=$((videoDuration/videoSplits+1))
        echo "Video Split Duration:      " $(date +%T -u -d @$minSplitDuration) "("$minSplitDuration" seconds)"

        # Split video and create new jsons
        previousSplit=0
        for ((i=1; i<=$videoSplits; i++)); do

            # Set new title / filename
            splitTitle="[ $i of $videoSplits ] "$videoTitle
            splitFilename=$videoFilename".part"$i
            splitJson="$tmpSplitDir/$splitFilename".$ytdlInfoExt
            echo "Split video into $splitTitle"

            # Split the video
            if [ $useFFMPEG = Y ]; then
                ffmpeg -loglevel error \
                    -ss $previousSplit \
                    -i "$videoFilePath" \
                    -t $minSplitDuration \
                    -c copy \
                    -map 0 \
                    "$splitFilename.$videoExt"
            else
                avconv -loglevel error \
                    -ss $previousSplit \
                    -i "$videoFilePath" \
                    -t $minSplitDuration \
                    -c copy \
                    -map 0 \
                    "$splitFilename.$videoExt"
            fi

            # Skip on error
            if [ $? -ne 0 ]; then
                echo "ERROR occurred while splitting the video on part %i"
                rm --recursive $tmpSplitDir
                recordSkipStats
                return $ec_ContinueNext
            fi

            # Extract the true duration from the final split video (sometimes not exactly as given)
            trueSplitDuration=minSplitDuration
            trueSplitDurationSTR=
            if [ $useFFMPEG = Y ]; then
                trueSplitDurationSTR=$( \
                    ffmpeg -i "$splitFilename.$videoExt" 2>&1 \
                    | grep --perl-regexp \
                    --only-matching \
                    "Duration: \K\d\d:\d\d:\d\d"
                    )
            else
                trueSplitDurationSTR=$( \
                    avconv -i "$splitFilename.$videoExt" 2>&1 \
                    | grep --perl-regexp \
                    --only-matching \
                    "Duration: \K\d\d:\d\d:\d\d"
                    )
            fi
            [ -z "$trueSplitDurationSTR" ] \
            || trueSplitDuration=$(timeInSeconds "$trueSplitDurationSTR")

            # Copy json with new info
            jq --compact-output \
                --arg vt "$splitTitle" \
                --arg du $trueSplitDuration \
                --arg pt $i '
                    .fulltitle = $vt |
                    .duration = $du |
                    .splitPart = $pt' \
                "$videoJson" \
                > "$splitJson"

            # Ensure json file was modified
            newDurationCheck=$(queryJson "duration" "$splitJson") || exit 1
            if [ "$newDurationCheck" != "$trueSplitDuration" ]; then
                echo "ERROR failed to create json file for split video part %i"
                rm --recursive $tmpSplitDir
                recordSkipStats
                return $ec_ContinueNext
            fi

            # Set next split start point
            ((previousSplit+=minSplitDuration))

        done

        # Move split json files only after success
        mv $tmpSplitDir/* "$outputDir"
        rm --recursive $tmpSplitDir

        # Delete/Keep orginal copy
        if [ $keepDownloadedVideos = Y ]; then
            [ -d "./$keepVideosDir" ] || mkdir "./$keepVideosDir"
            mv "./$videoFilePath" "./$keepVideosDir/$videoFilePath"
            mv "./$videoJson" "./$keepVideosDir/$videoJson"
        else
            rm --force "./$videoFilePath"
            rm --force "./$videoJson"
        fi

        # Run procedure to process existing jsons
        uploadsBefore=$totalVideosUploaded
        origVideoSplits=$videoSplits
        processExistingJsons

        # Correctly track count as only one video if all splits uploaded
        uploadsAfter=$totalVideosUploaded
        splitUploadsDone=$((uploadsAfter-uploadsBefore))
        if [ $splitUploadsDone -eq $origVideoSplits ]; then
            ((totalVideosRemaining+=splitUploadsDone-1))
        else
            ((totalVideosRemaining+=splitUploadsDone))
        fi

        # Restart timeout for duration allowance video search
        resetVideoSearchTimeout

        # Continue to next download
        return $ec_ContinueNext

    fi

}

prepareForUpload() {

    # Video id is required
    [ -z "$videoId" ] && raiseError "prepareForUpload: Video ID required!"

    # Check if reached requested upload amount
    if ! [ -z "$optCountOfUpload" ]; then
        if [ $totalVideosUploaded -ge $optCountOfUpload ]; then
            echo "Requested video count uploads ("$optCountOfUpload") reached for this session"
            return $ec_BreakLoop
        fi
    fi

    # Quit when reaches the max allowed uploads for this session
    if ! [ -z $remainingDailyVideosMAX ]; then
        if [ $remainingDailyVideosMAX -eq 0 ]; then
            echo "Reached the current window's daily video upload allowance"
            echo "Quitting..."
            return $ec_BreakLoop
        fi
    fi

    # Quit when the targetted remaining duration has been reached
    if ! [ -z $remainingDurationMAX ]; then
        if [ $remainingDurationMAX -le $targetRemainingDuration ]; then
            echo "Reached the current window's targetted upload allowance (i.e. targetRemainingDuration)"
            echo "Quitting..."
            return $ec_BreakLoop
        fi
    fi

    # Exit if the upload window has ended
    if [ $(date +%s) -gt $uploadWindowEnd ]; then
        echo "Upload Window has ended.  Quitting..."
        return $ec_BreakLoop
    fi

    # Get the duration of the video before download
    # Ensuring to use duration already set when json already already queried for this video id (e.g when spitting videos)
    if [ "$videoId" != "$ytVideoId" ]; then
        getVideoDuration || return $?
    fi

    # Check if video needs to be broken up into parts
    videoSplits=0
    queryVideoDuration=$videoDuration
    if [ $dmMaxVideoDuration -gt 0 ] && [ $videoDuration -gt $dmMaxVideoDuration ]; then
        # How many splits are required
        videoSplits=$((videoDuration/dmMaxVideoDuration+1))

        # Query the limits based on max upload size (don't use min size to avoid it priortising split videos over smaller ones)
        queryVideoDuration=$dmMaxVideoDuration
    fi

    # Skip if greater than max duration by window end
    if ! [ -z $remainingDurationMAX ]; then
        if [ $queryVideoDuration -gt $remainingDurationMAX ]; then
            echo "Skipping video ID $videoId, duration is "$(date +%T -u -d @$videoDuration) "("$videoDuration" seconds)"
            recordSkipStats
            return $ec_ContinueNext
        fi
    fi

    # Print start of new video
    echo "********************************************************************"
    if [ "$videoId" != "$ytVideoId" ]; then
        echo "**** Processing Youtube Video ID $videoId ***********************"
    else
        echo "**** Existing File: $videoFilename"
    fi
    echo "********************************************************************"

    # Get Daily Motion Upload Limits
    dmGetAllowance

    # If you have to wait beyond the upload window, then skip
    timeTillWindowEnds=$((uploadWindowEnd-$(date +%s)))
    if [ $waitingTime -gt $timeTillWindowEnds ]; then

        # Record skip reason
        echo -n "Cannot upload due to allowance restrictions on "
        waitReasonDescription $waitingForType

        # Ignore allowances?
        if [ $optIgnoreAllowance = Y ]; then
            echo "WARNING: option set to ignore upload allowances"
            echo "Continuing with upload anyway..."
            return $ec_Success
        fi

        # Skip to next video
        echo "Checking next video..."
        recordSkipStats
        return $ec_ContinueNext
    fi

    # If you have to wait close to the next scheduled start, then let that run pick up this video
    timeTillQuit=$((dmUploadQuitingTime-$(date +%s)))
    if [ $waitingTime -gt $timeTillQuit ]; then
        echo "Cannot upload video within the time remaining for the current schedule"
        recordSkipStats

        # Unless the target hasn't been reached yet
        if [ $remainingDurationMAX -le $targetRemainingDuration ]; then
            echo "Quitting..."
            return $ec_BreakLoop
        else
            echo "Skipping..."
            return $ec_ContinueNext
        fi
    fi

    # Print info on video split
    if [ $videoSplits -gt 0 ]; then
        echo "WARNING: Video is longer than the max allowed upload length"
        echo "Video will need split into $videoSplits parts"
    fi

}

rebuildAllowanceFile() {

    # Access token required
    [ -z "$dmAccessToken" ] && raiseError "rebuildAllowanceFile: dailymotion access token required!"

    # Backup existing file
    [ -f "$allowanceFile" ] && cp "$allowanceFile" "$allowanceFile.bku"

    # Query daily motion for uploads in last 24 hours and save to file
    sort -n <<< "$(dmQueryUploadInAllowancePeriod)" > "$allowanceFile"

    # Markup success
    echo ""
    echo "The local upload limits tracking file has been sync'd with actual uploads from your dailymotion account"

}

dmTrackAllowance() {

    # Convert local time to server time
    uploadTime=$(date +%s)
    ((uploadTime+=dmTimeOffset))

    # Write to file
    echo $uploadTime $@ >> "$allowanceFile"

}

dmGetAllowance() {

    # Print the allowance?
    printAllowances=Y
    [ "$1" = "--do-not-print" ] && printAllowances=N

    # Reset Dailymotion upload limits
    remainingDuration=$dmDurationAllowance
    #remainingVideos=$dmVideoAllowance # (NOTE: Old limit no longer enforced)
    remainingDailyVideos=$dmVideosPerDay
    remainingDurationMAX=$dmDurationAllowance
    remainingDailyVideosMAX=$dmVideosPerDay

    # Reset Return values
    recsInLastDay=
    oldestVideoThisDay=0
    oldestVideoThisHour=0
    VideoBlockingUpload=0
    latestUploadTime=0
    videoLimitWaitTill=0
    durationLimitWaitTill=0
    dailyLimitWaitTill=0
    maxWaitTill=0
    remainingDurationSoon=0
    waitingTime=0
    unpublishedVideosExist=N

    # Create Limits tracking file if it doesn't exist
    [ -f "$allowanceFile" ] || rebuildAllowanceFile

    # Time range to check
    currentTime=$(date +%s)
    durationUploadWindow=$((currentTime-$dmDurationAllowanceExpiry))
    hourlyUploadWindow=$((currentTime-$dmVideoAllowanceExpiry))
    durationUploadWindowMAX=$((uploadWindowEnd-$dmDurationAllowanceExpiry))

    # Review previous uploads
    readarray recs < "$allowanceFile"
    for rec in "${recs[@]}"; do
        recArr=(${rec})
        uploadTime=${recArr[0]}
        [ -z "$uploadTime" ] && continue
        uploadDur=${recArr[1]}
        uploadId=${recArr[2]}
        uploadStatus=${recArr[3]}

        # Ensure values exists
        if ! isNumeric $uploadTime; then
            echo "uploadTime is non-numeric: $uploadTime $uploadDur"
            continue
        fi
        if ! isNumeric $uploadDur; then
            echo "uploadDur is non-numeric: $uploadTime $uploadDur"
            continue
        fi

        # Print full times for debugging
        if [ $optDebug = Y ]; then
            echo $uploadId $(date -d @$uploadTime) $(date +%T -u -d @$uploadDur) "("$uploadDur")" $uploadStatus
        fi

        # Convert server time to local time
        ((uploadTime-=dmTimeOffset))

        # Videos in the last day
        if [ $uploadTime -ge $durationUploadWindow ]; then

            # Track Duration Limits
            remainingDuration=$((remainingDuration-uploadDur))
            if [ -z "$recsInLastDay" ]; then
                recsInLastDay="${recArr[@]}"
            else
                recsInLastDay+=$'\n'"${recArr[@]}"
            fi

            # Track Daily Limits
            ((remainingDailyVideos-=1))
            if [ $oldestVideoThisDay -eq 0 ]; then
                oldestVideoThisDay=$uploadTime
            fi

            # Track if unpublished videos exists
            if ! [ -z "$uploadId" ] && [ "$uploadStatus" != "published" ]; then
                unpublishedVideosExist=Y
            fi
        fi

        # Videos in the current upload window
        if [ $durationUploadWindowMAX -gt 0 ] && [ $uploadTime -ge $durationUploadWindowMAX ]; then
            remainingDurationMAX=$((remainingDurationMAX-uploadDur))
            ((remainingDailyVideosMAX-=1))
        fi

        # Videos in the last hour
        if [ $uploadTime -ge $hourlyUploadWindow ]; then
            #((remainingVideos-=1)) # (NOTE: Old limit no longer enforced)
            [ $oldestVideoThisHour -eq 0 ] && oldestVideoThisHour=$uploadTime
        fi

        # Record time of most recent upload
        latestUploadTime=$uploadTime

    done
    recs=

    # Calculate when enough duration will be available
    if [ $queryVideoDuration -gt $remainingDuration ]; then

        # Review file again to work out earliest point
        remainingDurationSoon=$remainingDuration
        #readarray recs <<< "$(tac "$allowanceFile")" #from the bottom upload
        readarray recs <<< "$recsInLastDay"
        for rec in "${recs[@]}"; do
            recArr=(${rec})
            uploadTime=${recArr[0]}
            uploadDur=${recArr[1]}

            # Convert server time to local time
            ((uploadTime-=dmTimeOffset))

            # Will this provide enough?
            ((remainingDurationSoon+=uploadDur))
            if [ $remainingDurationSoon -gt $queryVideoDuration ]; then
                VideoBlockingUpload=$uploadTime
                break
            fi
        done
        recs=
    fi

    # Clear down tracking file to within a day
    echo "$recsInLastDay" > "$allowanceFile"

    # Print Info
    [ $remainingDuration -lt 0 ] && remainingDuration=0
    if [ $printAllowances = Y ]; then
        logAction "Checking upload allowances"
        echo "  Current video duration:            " $(date +%T -u -d @$videoDuration) "("$videoDuration" seconds)"
        echo "  Remaining duration (now):          " $(date +%T -u -d @$remainingDuration) "("$remainingDuration" seconds)"
        echo "  Remaining duration (session):      " $(date +%T -u -d @$remainingDurationMAX) "("$remainingDurationMAX" seconds)"
        #echo "  Remaining hourly uploads:          " $remainingVideos  #(NOTE: Old limit no longer enforced)
        echo "  Remaining daily uploads (now):     " $remainingDailyVideos
        echo "  Remaining daily uploads (session): " $remainingDailyVideosMAX
    fi

    # Default minimum wait time between uploads
    minimumWaitTill=$((latestUploadTime+dmWaitTimeBetweenUploads))
    maxWaitTill=$minimumWaitTill
    waitingForType=$wr_minimumTime

    # Check if videos per hour limit reached (NOTE: Old limit no longer enforced)
    #if [ $remainingVideos -lt 1 ]; then
    #    videoLimitWaitTill=$((oldestVideoThisHour+dmVideoAllowanceExpiry))
    #    if [ $videoLimitWaitTill -gt $maxWaitTill ]; then
    #        maxWaitTill=$videoLimitWaitTill
    #        waitingForType=$wr_hourlyLimit
    #    fi
    #fi

    # Check if duration limit reached
    if [ $remainingDuration -lt $queryVideoDuration ]; then
        durationLimitWaitTill=$((VideoBlockingUpload+dmDurationAllowanceExpiry))
        if [ $durationLimitWaitTill -gt $maxWaitTill ]; then
            maxWaitTill=$durationLimitWaitTill
            waitingForType=$wr_durationLimit
        fi
    fi

    # Check if daily uploads limit reached
    if [ $remainingDailyVideos -lt 1 ]; then
        dailyLimitWaitTill=$((oldestVideoThisDay+dmDurationAllowanceExpiry))
        if [ $dailyLimitWaitTill -gt $maxWaitTill ]; then
            maxWaitTill=$dailyLimitWaitTill
            waitingForType=$wr_dailyLimit
        fi
    fi

    # Get initial waiting time
    waitingTime=$((maxWaitTill+dmExpiryToleranceTime-$(date +%s)))

}

waitForUploadAllowance() {

    # Given target wait time
    targetTime=$1
    targetMessage=$2
    isNumeric $targetTime || targetTime=0
    [ $targetTime -gt 0 ] || targetTime=0

    # Use the waiting time to check if previous video has published yet (and update with the correct published time)
    if [ $unpublishedVideosExist = Y ]; then
        checkTill=$((maxWaitTill-targetTime))
        if [ $checkTill -gt $(date +%s) ]; then
            printInfoOnWaitReason
            checkOnPublishingVideos
            resetVideoSearchTimeout
        fi
    fi

    # Exit if no waiting time required
    waitingTime=$((maxWaitTill+dmExpiryToleranceTime-$(date +%s)))
    [ $waitingTime -le $targetTime ] && return $ec_Success

    # Ignore allowances?
    if [ $optIgnoreAllowance = Y ]; then
        echo "WARNING: option set to ignore upload allowances. Meant to wait till "$(date -d @$maxWaitTill)" but continuing anyway..."
    else
        # Required Sleep Time
        sleepTime=$((waitingTime-targetTime))
        sleepTill=$((maxWaitTill-targetTime+dmExpiryToleranceTime))

        # Sleep
        printInfoOnWaitReason
        echo "  Waiting till "$(date +%X -d @$sleepTill) $targetMessage
        [ -t 0 ] && echo "(Or press Ctrl+C to quit instead)"
        sleep $sleepTime

        # Reset timeout after sleep
        resetVideoSearchTimeout
    fi

}

printInfoOnWaitReason() {

    # Detailed info message for wait reason (only prints the first time)
    if ! [ "$waitInfoPrinted" = "Y" ]; then
        echo -n "  Not posting video until "$(date +%X -d @$maxWaitTill)" due to "
        waitReasonDescription $waitingForType
        waitInfoPrinted=Y
    fi

}

waitReasonDescription() {

    # Convert the wait reason enum to a description
    case $1 in
        $wr_minimumTime)    echo "the minimum wait time between uploads";;
        $wr_hourlyLimit)    echo "the hourly upload limit";;
        $wr_durationLimit)  echo "the duration allowance";;
        $wr_dailyLimit)     echo "the max daily videos limit";;
        *)                  echo "an unspecified wait limit!?";;
    esac

}

logAction() {

    # Short procedure to prefix date to logged action
    echo $(date +%X) "- $@ ..."

}

uploadToDailyMotion() {

    # Requires Title
    [ -z "$videoTitle" ] && raiseError "Video Title required!"

    # Wait 30 minutes before the required time before uploading
    waitForUploadAllowance $waitTimeBeforeUploading "before uploading"

    # Renew Access Token (if required)
    renewDailyMotionAccess

    # Upload the Video
    logAction "uploading video"
    dmUploadFile "$videoFilePath" || exit 1
    if [ -z "$dmPostedUrl" ]; then
        raiseError "No Response from upload url!?"
    fi

    # Wait full required time for required allowance to be available
    waitForUploadAllowance 0 "before posting to account"

    # Renew Access Token (if required)
    renewDailyMotionAccess

    # Post the video to channel
    logAction "post video to channel"
    dmServerResponse=$(curl --silent --request POST \
        --header "Authorization: Bearer ${dmAccessToken}" \
        --data "url=$dmPostedUrl" \
        https://api.dailymotion.com/me/videos
    )

    # Check for failure to post video
    dmVideoId=$(queryJson "id" "$dmServerResponse") || exit 1
    if [ "$dmVideoId" = "null" ]; then

        # Print full details of the error
        echo "Failed post the video to the account!$(dmResponsePrettyPrint)"

        # Suspend account for 24 hours if limits exceeded
        # https://faq.dailymotion.com/hc/en-us/articles/115009030568-Upload-policies
        dmErrorReason=$(queryJson "error.error_data.reason" "$dmServerResponse") || exit 1
        if [ "$dmErrorReason" = "upload_limit_exceeded" ]; then
            echo "Upload limit exceeded!"
            echo "Upload privileges suspended till "$(date -d "+$dmDurationAllowanceExpiry seconds")
            echo "For more info check: https://www.dailymotion.com/upload"

            # Show whats being uploaded in past day...
            echo ""
            echo "Running --show-dm-uploads command for your review..."
            echoUploadsToday

            # Markup that account is locked out for 24-hours
            dmTrackAllowance $dmDurationAllowance

            # Exit the program
            exitRoutine
        fi

        # Track the duration just encase
        #dmTrackAllowance $videoDuration

        # Move to failed folder (so that it doesn't keep trying to upload a post it)
        echo "Moving video to the failed directory..."
        [ -d "./$failedVideosDir" ] || mkdir "./$failedVideosDir"
        mv "./$videoFilePath" "./$failedVideosDir/$videoFilePath"
        mv "./$videoJson" "./$failedVideosDir/$videoJson"
        echo "$(dmResponsePrettyPrint)" > "./$failedVideosDir/${videoFilePath}.error"

        # Try next video
        return $ec_ContinueNext

    fi

    # Initially track against current time (but will be updated later to the published time)
    dmServerResponse=$(dmGetFieldValue video/$dmVideoId duration)
    dmDuration=$(queryJson "duration" "$dmServerResponse") || exit 1
    dmTrackAllowance $dmDuration $dmVideoId "waiting"

    # Publish the video
    logAction "publishing video"
    dmServerResponse=$(publishVideo)
    dmPublishedVideoId=$(queryJson "id" "$dmServerResponse") || exit 1
    if [ "$dmPublishedVideoId" = "null" ]; then
        # Print the error for review
        raiseError "Failed publish the video ID $dmVideoId !$(dmResponsePrettyPrint)"
    fi

    # Update upload statistics
    ((totalVideosUploaded++))
    ((totalDurationUploaded+=videoDuration))
    ((remainingDurationMAX-=videoDuration))
    ((remainingDailyVideosMAX--))

    # Record upload to json file
    mirrorDate=$(date +"%d-%b-%y %R")
    jq --null-input \
        --compact-output \
        --arg md "$mirrorDate" \
        --arg ut "$ytVideoId" \
        --arg dm "$dmVideoId" \
        --arg du $videoDuration \
        --arg pt "$videoPart" \
        --arg vt "$videoTitle" \
        '{mirrorDate: $md, youtubeId: $ut, dailyMotionId: $dm, duration: $du, part: $pt, title: $vt}' \
        >> "$publishedUploadsFile"

    # Record upload to csv file
    if ! [ -f "$publishedUploadsFileCSV" ]; then
        echo "Mirror_Date,YouTube_ID,Dailymotion_ID,Duration,Part_No,Title" > "$publishedUploadsFileCSV"
    fi
    echo "${mirrorDate},${ytVideoId},${dmVideoId},${videoDuration},${videoPart},\"${videoTitle}\"" >> "$publishedUploadsFileCSV"

    # Delete/Keep local files
    if [ $keepDownloadedVideos = Y ] && ! isNumeric $videoPart; then
        [ -d "./$keepVideosDir" ] || mkdir "./$keepVideosDir"
        mv "./$videoFilePath" "./$keepVideosDir/$videoFilePath"
        mv "./$videoJson" "./$keepVideosDir/$videoJson"
    else
        rm --force "./$videoFilePath"
        rm --force "./$videoJson"
    fi

    # Update previous part with link to this part
    dmServerResponse=$(dmGetFieldValue video/$dmVideoId url)
    dmVideoUrl=$(queryJson "url" "$dmServerResponse") || exit 1
    addLinkToPrevVideoPart

}

tablePrintPublishedJson() {

    # Initial attempt at printing the csv file
    #column -s, -t "$publishedUploadsFileCSV" \
    #    | less --shift=2 \
    #    --LINE-NUMBERS \
    #    --chop-long-lines \
    #    --quit-on-intr \
    #    || echo ""

    # Print the json file in table layout
    cat <(echo $'Mirror Date\tYoutube Video\tDailymotion Video\tDuration\tVideo Title') \
        <(jq --raw-output --slurp \
            'reverse | .[] |
            "\(.mirrorDate
            )\thttps://youtu.be/\(.youtubeId
            )\thttps://dai.ly/\(.dailyMotionId
            )\t\(if .duration==null then "null" else
                .duration|tonumber|[./60/60%24, ./60%60, .%60]
                |"\(if .[0]>0 then "\(.[0])h " else "" end
                 )\(if .[1]>0 then "\(.[1])m " else "" end
                 )\(.[2])s" end
            )\t\(.title)"' \
            "$publishedUploadsFile"
          2>&1 ) \
        | column -s$'\t' -t \
        | less --shift=2 \
            --LINE-NUMBERS \
            --chop-long-lines \
            --quit-on-intr \
        || echo -n ""

}

publishVideo() {

    # Publish the video (and return json)
    curl --silent --request POST \
        --header "Authorization: Bearer ${dmAccessToken}" \
        --data "published=true" \
        --data "channel=$uploadVideoInCategory" \
        --data-urlencode "title=$videoTitle" \
        ${dmVideoDescr:+ --data-urlencode "description=$dmVideoDescr"} \
        ${youtubeVideoTags:+ --data-urlencode "tags=$youtubeVideoTags"} \
        ${uploadVideoWithNextVideoIdPlayback:+ --data-urlencode "player_next_video=$uploadVideoWithNextVideoIdPlayback"} \
        ${uploadVideoWithPassword:+ --data-urlencode "password=$uploadVideoWithPassword"} \
        ${mirrorVideoThumbnailsOpt:+ --data "thumbnail_url=$videoThumbnail"} \
        ${uploadVideoAsPrivateOpt:+ --data "private=true"} \
        ${uploadVideoAsCountryCode:+ --data "country=$uploadVideoAsCountryCode"} \
        https://api.dailymotion.com/video/$dmVideoId

}

checkOnPublishingVideos() {

    # Info
    echo "    Checking on previous uploads which did not finish publishing..."

    # Variable to hold replacement times
    newFileContent=

    # Marker if file needs resorted
    resortFile=N

    # Reset unpublished check
    unpublishedVideosExist=N

    # Find the unpublished videos marked on the tracking file
    readarray recs < "$allowanceFile"
    for rec in "${recs[@]}"; do
        recArr=(${rec})
        uploadDur=${recArr[1]}
        [ -z "$uploadDur" ] && continue
        uploadId=${recArr[2]}
        uploadStatus=${recArr[3]}
        uploadLine=${recArr[@]}

        # Is still to publish?...
        if ! [ -z "$uploadId" ] && [ "$uploadStatus" != "published" ]; then
            waitForPublish $uploadId $checkTill

            # Mark up if still not published
            if ! [ $dmStatus = "published" ]; then
                echo "    Will check up on this video again later"
                unpublishedVideosExist=Y
            fi

            # Update with latest timestamp/duration/status from dailymotion
            dmCreatedTime=$(queryJson "created_time" "$dmServerResponse") || exit 1
            dmDuration=$(queryJson "duration" "$dmServerResponse") || exit 1
            uploadLine="$dmCreatedTime $dmDuration $uploadId $dmStatus"

            # Mark up that the file will need resorted
            resortFile=Y
        fi

        # Concatenate new line
        if [ -z "$newFileContent" ]; then
            newFileContent="$uploadLine"
        else
            newFileContent+=$'\n'"$uploadLine"
        fi
        
        # Break loop when time limit passed
        [ $(date +%s) -gt $checkTill ] && break

    done

    # Write update to tracking file
    if [ $resortFile = Y ]; then
        sort -n <<< "$newFileContent" > "$allowanceFile"
    else
        echo "$newFileContent" > "$allowanceFile"
    fi

}

waitForPublish() {

    # Inputs
    dmVideoId=$1
    publishWaitTill=$2

    # Check id is valid
    videoFields="created_time,status,title,encoding_progress,publishing_progress,explicit,duration"
    dmServerResponse=$(dmGetFieldValue video/$dmVideoId "$videoFields")
    dmIdCheck=$(queryJson "id" "$dmServerResponse") || exit 1
    if [ "dmIdCheck" = "null" ]; then
        raiseError "Invalid video ID ${dmVideoId}! $(dmResponsePrettyPrint)"
    fi

    # Wait for video to finish encoding/publishing
    if [ $(date +%s) -lt $publishWaitTill ]; then
        until [ $(date +%s) -gt $publishWaitTill ]; do

            # Query video info
            renewDailyMotionAccess
            dmServerResponse=$(dmGetFieldValue video/$dmVideoId "$videoFields")
            dmStatus=$(queryJson "status" "$dmServerResponse") || exit 1

            # Quit loop on unexpected status (or published)
            [ $dmStatus != "waiting" ] && \
            [ $dmStatus != "processing" ] && \
            [ $dmStatus != "ready" ] && break

            sleep 30
        done

        # Double-check video is published
        dmVideoTitle=$(queryJson "title" "$dmServerResponse") || exit 1
        if [ $dmStatus != "published" ]; then
            dmEncodingPC=$(queryJson "encoding_progress" "$dmServerResponse") || exit 1
            dmPublishingPC=$(queryJson "publishing_progress" "$dmServerResponse") || exit 1
            echo "    Video ID $dmVideoId is still not published! - $dmVideoTitle"
            echo "          Status:              " $dmStatus
            echo "          Encoding Progress:   " $dmEncodingPC"%"
            echo "          Publishing Progress: " $dmPublishingPC"%"
        else
            echo "    Successfully published $dmVideoTitle"
        fi

        # Warn if video was flagged as Explicit
        dmExplicit=$(queryJson "explicit" "$dmServerResponse") || exit 1
        if [ "$dmExplicit" = "true" ]; then
            echo "    WARNING: Video ID $dmVideoId was flagged as Explicit! - $dmVideoTitle"
        fi
    fi
    
}

addLinkToPrevVideoPart() {

    # Not Required
    isNumeric $videoPart || return $ec_Error
    [ $videoPart -gt 1 ] || return $ec_Error

    # Find the id of the previous part
    prevPart=$((videoPart-1))
    echo "Editing part $prevPart description to included a link to part $videoPart..."
    prevPublishedPart=$(jq \
        --arg ut "$ytVideoId" \
        --arg pt "$prevPart" \
        'select(.youtubeId == $ut and .part == $pt)' \
        "$publishedUploadsFile"
    )
    prevDmId=$(queryJson "dailyMotionId" "$prevPublishedPart") || exit 1
    [ "$prevDmId" = "null" ] && raiseError "Unable to determine previous part of this video!?"

    # Get video info
    dmServerResponse=$(dmGetFieldValue video/$prevDmId "status,player_next_video,description")
    prevDmStatus=$(queryJson "status" "$dmServerResponse") || exit 1
    if  [ $prevDmStatus != "waiting" ] && \
        [ $prevDmStatus != "processing" ] && \
        [ $prevDmStatus != "ready" ] && \
        [ $prevDmStatus != "published" ]; then
            raiseError "Previous Part id $prevDmId has an unexpected status of ${prevDmStatus}!? $(dmResponsePrettyPrint)"
    fi

    # Exit if next part has already been set
    prevDmNextId=$(queryJson "player_next_video" "$dmServerResponse") || exit 1
    if [ "$prevDmNextId" = "$dmVideoId" ]; then
        echo "Previous video already has link.  Canceled edit"
        return $ec_Error
    fi

    # Update description with next part
    prevDmDescr=$(queryJson "description" "$dmServerResponse") || exit 1
    prevDmDescr="Watch Part ${videoPart}:"$'\n'"$dmVideoUrl"$'\n\n'"$prevDmDescr"

    # Edit previous video with links to next part
    dmServerResponse=$(curl --silent --request POST \
        --header "Authorization: Bearer ${dmAccessToken}" \
        --data-urlencode "description=$prevDmDescr" \
        --data-urlencode "player_next_video=${dmVideoId}" \
        https://api.dailymotion.com/video/$prevDmId
    )
    dmEditedVideoId=$(queryJson "id" "$dmServerResponse") || exit 1
    if [ "$dmEditedVideoId" = "null" ]; then
        raiseError "Failed to update previous part ID ${prevDmId}! $(dmResponsePrettyPrint)"
    fi
    echo "Successfully edited video id $dmEditedVideoId"

}

dmUploadFile() {

    # Cleat Output Argument
    dmPostedUrl=

    # Input argument
    uploadFilePath=$@
    if ! [ -f "$uploadFilePath" ]; then
        printError "Upload File does not exist!? $uploadFilePath"
        return $ec_Error
    fi

    # Generate a new upload url
    dmServerResponse=$(dmGetFieldValue file/upload)
    dmUploadUrl=$(queryJson "upload_url" "$dmServerResponse") || exit 1
    if [ "$dmUploadUrl" = "null" ]; then
        raiseError "Unable to get an upload url for dailymotion.com! $(dmResponsePrettyPrint)"
    fi

    # Upload the file
    dmServerResponse=$(curl --silent --request POST \
        --form "file=@\"$uploadFilePath\"" \
        $dmUploadUrl
    )
    dmPostedUrl=$(queryJson "url" "$dmServerResponse") || exit 1
    if [ "$dmPostedUrl" = "null" ]; then
        dmPostedUrl=
        raiseError "Failed to upload the file to dailymotion.com! $(dmResponsePrettyPrint)"
    fi

}

dmGetFieldValue() {

    # Context and field value provided on parameters
    fieldContext=$1
    fieldName=$2

    # Return full response
    curl --silent \
        --header "Authorization: Bearer ${dmAccessToken}" \
        ${fieldName:+ --data "fields=$fieldName"} \
        https://api.dailymotion.com/$fieldContext

}

dmChangeUserField() {

    # Field name provided in first argument
    changeFieldName=$1
    [ -z "$changeFieldName" ] && raiseError "Missing Argument 1 - the name of the field to change"

    # Get current field value
    dmServerResponse=$(dmGetFieldValue me $changeFieldName)
    currentFieldValue=$(queryJson "$changeFieldName" "$dmServerResponse") || exit 1
    if [ "$currentFieldValue" = "null" ]; then
        raiseError "Unexpected response!?  Ensure field name '$changeFieldName' is valid $(dmResponsePrettyPrint)"
    fi

    # Confirm current field name
    echo ""
    echo "Current $changeFieldName:  " $currentFieldValue

    # Prompt for new value
    read -e -r -p "Change $changeFieldName to: " -i "$currentFieldValue" newFieldValue

    # Exit if not provided
    if [ -z "$newFieldValue" ] || [ "$currentFieldValue" = "$newFieldValue" ]; then
        echo "$changeFieldName change cancelled!"
        exit
    fi

    # Attempt change
    dmServerResponse=$(curl --silent --request POST \
        --header "Authorization: Bearer ${dmAccessToken}" \
        --data-urlencode "$changeFieldName=$newFieldValue" \
        https://api.dailymotion.com/me
        )
    dmResponseID=$(queryJson "id" "$dmServerResponse") || exit 1
    if [ "$dmResponseID" = "null" ]; then
        raiseError "Unexpected response!? $(dmResponsePrettyPrint)"
    fi

    # Check if sucessful
    dmServerResponse=$(dmGetFieldValue me $changeFieldName)
    replacedFieldValue=$(queryJson "$changeFieldName" "$dmServerResponse") || exit 1
    if [ "$replacedFieldValue" = "null" ]; then
        raiseError "Unexpected response!? $(dmResponsePrettyPrint)"
    fi
    if [ "$replacedFieldValue" = "$newFieldValue" ]; then
        echo "Successfully changed $changeFieldName to $replacedFieldValue"
    else
        echo "Failed to change ${replacedFieldValue}!  Value is still $replacedFieldValue"
    fi

}

uploadChannelArt() {

    # Get Arguments
    artType=$1
    imgFile=$2

    # Check file exists
    imgFile=$(readlink -f $imgFile)
    [ -f "$imgFile" ] || raiseError "image file does not exist: $imgFile"

    # Check type is valid
    if [ "$artType" != "avatar" ] && [ "$artType" != "cover" ]; then
        raiseError "invalid arg1.  Expected either 'avatar' or 'cover'"
    fi

    # Login
    initializeDailyMotion

    # Upload file to server
    dmUploadFile "$imgFile" || exit 1
    [ -z "$dmPostedUrl" ] && raiseError "failed to upload image file: $imgFile"

    # Update Channel
    dmServerResponse=$(curl --silent --request POST \
        --header "Authorization: Bearer ${dmAccessToken}" \
        --data "${artType}_url=$dmPostedUrl" \
        https://api.dailymotion.com/me \
        )

    dmCheckAcctId=$(queryJson "id" "$dmServerResponse") || exit 1
    if [ "$dmCheckAcctId" = "null" ]; then
        raiseError "Failed upload account artwork! $(dmResponsePrettyPrint)"
    fi

    # Success
    echo "Successfully uploaded account "$artType" art"

}

syncVideoDetails() {

    # Ensure video ID has been uploaded previously
    uploadInfoJson=$(jq \
        --compact-output \
        --arg dm "$optSyncDailyMotionID" \
        'select(.dailyMotionId == $dm)' \
        "$publishedUploadsFile"
    )
    [ -z "$uploadInfoJson" ] \
        && raiseError "Could not find dailymotion Video ID in uploaded list: $optSyncDailyMotionID"
    echo "Syncing dailymotion Video ID " $optSyncDailyMotionID
    dmVideoId=$optSyncDailyMotionID

    # Get youtube video id
    ytVideoId=$(queryJson "youtubeId" "$uploadInfoJson") || exit 1
    [ "$ytVideoId" = "null" ] && raiseError "Could not find match youtube video id!"
    echo "...to youtube video ID " $ytVideoId

    # Extract dailymoton video details
    initializeDailyMotion
    videoFields="status,published,channel,title,explicit,duration,country,private,password,url,thumbnail_url,player_next_videos,tags,description"
    dmServerResponse=$(dmGetFieldValue video/$dmVideoId "$videoFields")
    dmConfirmedVideoId=$(queryJson "id" "$dmServerResponse") || exit 1
    [ "$dmConfirmedVideoId" = "null" ] \
        && raiseError "Could not get video from dailymotion!? $(dmResponsePrettyPrint)"

    # Print existing details
    echo "dailymotion.com video info before change: "
    echo "$(jq '.' <<< "$dmServerResponse")"

    # Download Youtube json file
    echo "Connecting to youtube-dl to get video info..."
    videoJson=$(mktemp)
    $ytdl --dump-json -- $ytVideoId > $videoJson

    # Extract youtube video details
    getYouTubeInfoFromJson
    rm $videoJson

    # Update fields to account for video split parts
    videoPart=$(queryJson "part" "$uploadInfoJson") || exit 1
    if isNumeric $videoPart; then
        dmVideoUrl=$(queryJson "url" "$dmServerResponse") || exit 1
        videoTitle=$(queryJson "title" "$uploadInfoJson") || exit 1
        uploadVideoWithNextVideoIdPlayback=
    fi

    # Update Daily Motion video
    echo "Updating dailymotion video..."
    dmServerResponse=$(publishVideo)
    dmPublishedVideoId=$(queryJson "id" "$dmServerResponse") || exit 1
    if [ "$dmPublishedVideoId" = "null" ]; then
        raiseError "Failed edit the video ID ${dmVideoId}! $(dmResponsePrettyPrint)"
    fi

    # Update previous part as well
    addLinkToPrevVideoPart

    # Mark up success
    echo "Successfully updated video!"
}

dmQueryUploadInAllowancePeriod() {

    # Input Arguments
    formatReadable=N
    [ "$1" = "--readable" ] && formatReadable=Y

    # Current upload allowance range
    dmCreatedAfterFilter=$(date +%s -d "-$((dmDurationAllowanceExpiry+1000)) seconds")

    # Track total duration
    dmTotalDuration=0

    # Loop result pages
    dmHasMore="true"
    dmPage=0
    while [ "$dmHasMore" = "true" ]; do
        ((dmPage++))

        # Get list of videos uploaded in the last day
        dmServerResponse=$(curl --silent \
            --header "Authorization: Bearer ${dmAccessToken}" \
            "https://api.dailymotion.com/me/videos?page=${dmPage}&created_after=${dmCreatedAfterFilter}"
        )
        dmHasMore=$(queryJson "has_more" "$dmServerResponse") || exit 1
        dmPageResp=$(queryJson "page" "$dmServerResponse") || exit 1
        if [ $dmPageResp -ne $dmPage ]; then
            raiseError "Did not get the expected page number!"
            exit
        fi

        # Loop through list
        for dmVideoId in $(jq --raw-output ".list[] | .id" <<< "$dmServerResponse"); do
            dmServerResponse=$(dmGetFieldValue video/$dmVideoId "created_time,duration,status")
            dmCreatedTime=$(queryJson "created_time" "$dmServerResponse") || exit 1
            dmDuration=$(queryJson "duration" "$dmServerResponse") || exit 1
            dmStatus=$(queryJson "status" "$dmServerResponse") || exit 1
            ((dmTotalDuration+=dmDuration))

            # echo results
            if [ $formatReadable = Y ]; then
                echo $dmVideoId $(date -d @$dmCreatedTime) $(date +%T -u -d @$dmDuration) "("$dmDuration")" $dmStatus
            else
                echo $dmCreatedTime $dmDuration $dmVideoId $dmStatus
            fi
        done
    done

}

showUploadsDoneToday() {

    # Show uploads from daily motion
    echo ""
    echo "Uploads to dailymotion.com in last 24 hours..."
    dmQueryUploadInAllowancePeriod --readable
    echo "Total Upload Duration: " $((dmTotalDuration/60/60))"h "$(date +"%Mm %Ss" -u -d @$dmTotalDuration) "("$dmTotalDuration")"

    # Print info on when next upload can be done
    waitingTime=$((maxWaitTill+dmExpiryToleranceTime-$(date +%s)))
    if [ $waitingTime -gt 0 ]; then
        echo ""
        echo "Next upload allowance will be freed at "$(date -d @$maxWaitTill)
    fi

}

echoUploadsToday() {

    # Show whats been published on dailymotion in past 24hrs
    showUploadsDoneToday

    # Query limits based on max video duration
    echo ""
    echo "Comparing with local tracking file..."
    optDebug=Y
    queryVideoDuration=$dmMaxVideoDuration
    dmGetAllowance --do-not-print
    optDebug=N

    # Display time to wait for max upload
    echo ""
    echo "Time to wait for max upload duration "$(date -d @$maxWaitTill)

}

initializeDailyMotion() {

    # Load the properties file
    loadPropertiesFile

    # Get access token for daily motion login
    getDailyMotionAccess

    # Get/Display info on the daily motion account used
    getUserInfo

}

testDailyMotionAvailablity() {

    testAvailablilty=hello
    dmServerResponse=$(curl --silent \
        https://api.dailymotion.com/echo?message=$testAvailablilty
    )
    dmMessageResponse=$(queryJson "message" "$dmServerResponse") || exit 1
    if [ "$dmMessageResponse" != "$testAvailablilty" ]; then
        raiseError "Could not get valid response from dailymotion.com!?  Website may not be available. $(dmResponsePrettyPrint)"
    fi

}

dmResponsePrettyPrint() {
    echo ""
    echo "Response from server:"
    jq '.' <<< "$dmServerResponse"
}

renewDailyMotionAccess() {

    # Check if access renewal required
    if [ $(date +%s) -gt $dmAccessRenewTime ]; then
        echo "Renewing Daily Motion Access Token..."
        getDailyMotionAccess
    fi

}

getDailyMotionAccess() {

    # Print info
    echo "Connecting to api.dailymotion.com ..."

    # Test website is available
    testDailyMotionAvailablity

    # Has access been granted?
    if [ -z "$dmRefreshToken" ]; then

        # Interactive mode required
        [ -t 0 ] || raiseError "Access not granted to a dailymotion account!"$'\n'"Run from terminal manually to provide login details"

        # Run procedure to grant access
        grantDailyMotionAccess

    else

        # API key required
        [ -z "$dmApiKey" ]    && raiseError "dailyMotion API keys required!"
        [ -z "$dmApiSecret" ] && raiseError "dailyMotion API secret required!"

        # Refresh access token
        dmServerResponse=$(curl --silent \
            --data "grant_type=refresh_token" \
            --data "client_id=$dmApiKey" \
            --data "client_secret=$dmApiSecret" \
            --data "refresh_token=$dmRefreshToken" \
            https://api.dailymotion.com/oauth/token \
        )

    fi

    # Get Access Token
    dmAccessToken=$(queryJson "access_token" "$dmServerResponse") || exit 1
    if [ "$dmAccessToken" = "null" ]; then
        echo "Unable to get upload access to dailymotion.com! $(dmResponsePrettyPrint)"
        echo "Prompting for login info..."

        # Get new refresh token
        dmRefreshToken=
        getDailyMotionAccess
        exit
    fi

    # Track Expiry Time
    dmAccessExpiresIn=$(queryJson "expires_in" "$dmServerResponse") || exit 1
    [ "$dmAccessExpiresIn" = "null" ] \
        && raiseError "expires_in value not specified in response!?"
    dmAccessExpireTime=$(date +%s -d "+$dmAccessExpiresIn seconds")

    # Set time to renew the access token (1 hour before expiry)
    dmAccessRenewTime=$((dmAccessExpireTime-waitTimeBeforeUploading))

}

getUserInfo() {

    # Get Info on the current user
    dmServerResponse=$(dmGetFieldValue me "id,screenname,username,limits,created_time,status,partner,verified")
    dmAccountId=$(queryJson "id" "$dmServerResponse") || exit 1
    dmAccountName=$(queryJson "screenname" "$dmServerResponse") || exit 1
    [ "$dmAccountName" = "null" ] \
        && raiseError "Unable to get details of the upload user? $(dmResponsePrettyPrint)"

    # Check the Account is Active
    dmUserStatus=$(queryJson "status" "$dmServerResponse") || exit 1
    [ "$dmUserStatus" = "active" ] || raiseError "$dmAccountName Account Status is $dmUserStatus"

    # Extract other info
    dmMaxVideoDuration=$(queryJson "limits.video_duration" "$dmServerResponse") || exit 1
    dmMaxVideoSize=$(queryJson "limits.video_size" "$dmServerResponse") || exit 1
    dmIsParnter=$(queryJson "partner" "$dmServerResponse") || exit 1
    dmIsVerified=$(queryJson "verified" "$dmServerResponse") || exit 1
    dmUsername=$(queryJson "username" "$dmServerResponse") || exit 1

    # Mark up success
    echo "Channel Name:                   " $dmAccountName
    echo "Signed as Partner:              " $dmIsParnter
    echo "Verified Partner:               " $dmIsVerified
    echo "Max Allowed Duration:           " $(($dmMaxVideoDuration/60)) "minutes"
    echo "Max Allowed File Size:          " $(($dmMaxVideoSize/1024/1024)) "mb"
    echo "Access expires at:              " $(date -d @$dmAccessExpireTime)
    if [ $optDebug = Y ]; then
        echo "Access Token:                   " $dmAccessToken
    fi
    echo ""

    # Higher description length for partner accounts
    if [ $dmIsParnter = true ]; then
        dmMaxDescription=$dmMaxDescriptionForPartners
    else
        # Cannot upload thumbnails unless a partner
        if [ "$mirrorVideoThumbnailsOpt" = "Y" ]; then
            mirrorVideoThumbnailsOpt=
            printError "Cannot upload thumbnails unless using a Partner account!"
            printError "Please update your .prop file for mirrorVideoThumbnails=N"
            echo ""
        fi
    fi

    # Higher uploads per day limit if Verified Partner
    if [ $dmIsVerified = true ]; then
        dmVideosPerDay=$dmVideosPerDayForVerifiedPartners
    fi

    # Apply 1% tolerance to max file size
    dmMaxVideoSizeTolerance=$((dmMaxVideoSize/100*99))

    # Check for time difference between local PC and server
    checkServerTimeOffset

}

checkServerTimeOffset() {

    # Create a playlist
    dummyPlaylistName="DEV_timeCheck"$((RANDOM % 100))
    dmServerResponse=$(curl --silent --request POST \
        --header "Authorization: Bearer ${dmAccessToken}" \
        --data-urlencode "name=$dummyPlaylistName" \
        https://api.dailymotion.com/me/playlists
    )

    # Record local time
    localPCTime=$(date +%s)
    echo "Performing clock sync..."
    echo "Local PC Time:                  " $(date -d @$localPCTime)

    # Check for Error
    dmPlaylistID=$(queryJson "id" "$dmServerResponse") || exit 1
    if [ "$dmPlaylistID" = "null" ]; then
        raiseError "Failed to create playlist!? $(dmResponsePrettyPrint)"
    fi

    # Get created time of playlist (done on loop as it did once fail to read)
    queryTimeout=$(date +%s -d "+ 60 seconds")
    until [ $(date +%s) -gt $queryTimeout ]; do
        dmServerResponse=$(dmGetFieldValue playlist/$dmPlaylistID created_time)
        dmQueryError=$(queryJson "error" "$dmServerResponse") || exit 1
        [ "$dmQueryError" = "null" ] && break
        sleep 3
    done

    # Query the time from the response
    dmTime=$(queryJson "created_time" "$dmServerResponse") || exit 1
    if [ "$dmTime" = "null" ]; then
        raiseError "Failed to read playlist id ${dmPlaylistID}? $(dmResponsePrettyPrint)"
    fi

    # Show the difference
    dmTimeOffset=$((dmTime-localPCTime))
    echo "Dailymotion Time:               " $(date -d @$dmTime)
    echo "Time Difference:                " $dmTimeOffset " seconds"
    echo ""

    # Delete the playlist (done on loop as it did fail to delete once)
    deleteTimeout=$(date +%s -d "+ 60 seconds")
    until [ $(date +%s) -gt $deleteTimeout ]; do
        dmServerResponse=$(curl --silent --request DELETE \
            --header "Authorization: Bearer ${dmAccessToken}" \
            https://api.dailymotion.com/playlist/$dmPlaylistID
        )
        dmDeleteError=$(queryJson "error" "$dmServerResponse") || exit 1
        [ "$dmDeleteError" = "null" ] && break
        sleep 3
    done

    # Print Error if failed to delete
    if ! [ "$dmDeleteError" = "null" ]; then
        raiseError "Failed to delete playlist id ${dmPlaylistID}? $(dmResponsePrettyPrint)"
    fi

}

revokeDailyMotionAccess() {

    # Error if no accesss granted
    [ -z "$dmRefreshToken" ] && loadPropertiesFile
    [ -z "$dmRefreshToken" ] && raiseError "No access has been granted to any account!"

    # Existing access token required
    [ -z "$dmAccessToken" ] && getDailyMotionAccess
    [ -z "$dmAccessToken" ] && raiseError "Not currently logged in!  Cannot revoke access!"

    # Get current user name
    dmServerResponse=$(dmGetFieldValue me username)
    dmUsername=$(queryJson "username" "$dmServerResponse") || exit 1
    [ "$dmUsername" = "null" ] \
        && raiseError "Unable to get details of the user? $(dmResponsePrettyPrint)"

    # Are you sure?
    promptYesNo "Are you sure you want to logout of ${dmUsername}?"
    [ $? -eq $ec_Yes ] || exit

    # Logout
    dmServerResponse=$(curl --silent \
        --header "Authorization: Bearer ${dmAccessToken}" \
        https://api.dailymotion.com/logout \
        )

    # Check for error
    dmLogoutError=$(queryJson "error" "$dmServerResponse") || exit 1
    if ! [ "$dmLogoutError" = "null" ]; then
        raiseError "Failed to logout of account!? $(dmResponsePrettyPrint)"
    fi

    # Remove refresh token
    dmAccessToken=
    dmRefreshToken=
    echo "" >> "$propertiesFile"
    echo "" >> "$propertiesFile"
    echo "# Dailymotion Access Revoked for $dmUsername on $(date)" >> "$propertiesFile"
    echo "dmRefreshToken=" >> "$propertiesFile"

    # Markup success
    echo "Successfully logout out from $dmUsername"

}

grantDailyMotionAccess() {

    # Clear entry fields
    dmApiKey=
    dmApiSecret=
    dmUsername=
    dmPassword=

    # Prompt for login
    echo ""
    read -r -p "Enter Username for Dailymotion: " dmUsername
    [ -z "$dmUsername" ] && raiseError "No entry. Canceled Request"
    read -s -r -p "Enter Password: " dmPassword
    [ -z "$dmPassword" ] && raiseError "No entry. Canceled Request"
    echo ""

    # prompt for api keys
    echo ""
    echo "If you have not yet created your API key go to https://www.dailymotion.com/settings/developer"
    echo ""
    read -r -p "Enter API Key: " dmApiKey
    [ -z "$dmApiKey" ] && raiseError "No entry. Canceled Request"
    read -r -p "Enter API Secret: " dmApiSecret
    [ -z "$dmApiSecret" ] && raiseError "No entry. Canceled Request"

    # Test the login and grant refresh token
    echo "Testing login..."
    echo ""
    dmServerResponse=$(curl --silent \
        --data "grant_type=password" \
        --data "scope=userinfo+manage_videos+manage_playlists" \
        --data "client_id=$dmApiKey" \
        --data "client_secret=$dmApiSecret" \
        --data-urlencode "username=$dmUsername" \
        --data-urlencode "password=$dmPassword" \
        https://api.dailymotion.com/oauth/token \
    )
    dmPassword=
    dmRefreshToken=$(queryJson "refresh_token" "$dmServerResponse") || exit 1
    if [ "$dmRefreshToken" = "null" ]; then
        raiseError "Unable to get upload access to dailymotion.com! $(dmResponsePrettyPrint)"
    fi

    # Save keys and refresh token to properties file
    echo "" >> "$propertiesFile"
    echo "" >> "$propertiesFile"
    echo "# Dailymotion Authorised Account Access Keys" >> "$propertiesFile"
    echo "dmApiKey=\"$dmApiKey\"" >> "$propertiesFile"
    echo "dmApiSecret=\"$dmApiSecret\"" >> "$propertiesFile"
    echo "dmRefreshToken=\"$dmRefreshToken\"" >> "$propertiesFile"

    # Mark up sucessful
    echo "Successfully logged in"
    echo ""

}

dailyMotionReLogin() {

    # Load the properties file
    loadPropertiesFile

    # Login to existing token and revoke
    if ! [ -z "$dmRefreshToken" ]; then
        getDailyMotionAccess
        if ! [ -z "$dmAccessToken" ]; then
            promptYesNo "Access is already granted. Do you want to revoke the existing access and login again?"
            [ $? -eq $ec_Yes ] || exit
            revokeDailyMotionAccess
        fi
        dmRefreshToken=
    fi

    # Prompt user for new access
    grantDailyMotionAccess

    # Test the new login
    getDailyMotionAccess

    # Get/Display info on the daily motion account used
    getUserInfo

}

firstTimeSetup() {

    # Info
    echo "Entering First-Time-Setup mode..."

    # Interactive mode required
    [ -t 0 ] || raiseError "firstTimeSetup must only be run from the terminal manually!"

    # Install Dependencies
    installDependencies
    if [ $installRequired = Y ]; then
        echo ""
        echo "Please rerun the command to continue the first-time-setup"
        exit
    fi

    # Check if properties files already exists
    if [ -f "$propertiesFile" ]; then
        echo "WARNING .prop file already exists!"
        promptYesNo "This will revert your settings. Are you sure you want to continue?"
        [ $? -eq $ec_Yes ] || exit

        # Load the properties file
        loadPropertiesFile

        # Login to existing token and revoke
        if ! [ -z "$dmRefreshToken" ]; then
            echo "logging in to dailymotion, in order to revoke the access rights..."
            echo ""
            getDailyMotionAccess
            if ! [ -z "$dmAccessToken" ]; then
                promptYesNo "Are you sure you want to revoke the existing access rights to dailymotion and setup again?"
                [ $? -eq $ec_Yes ] || exit
                revokeDailyMotionAccess
            fi
            dmRefreshToken=
        fi
    fi

    # Get user to author the urls file
    echo ""
    echo "Initializing First Time Setup..."
    echo "You will be moved to a file editor to provide further information"
    echo ""
    pause
    createUrlsFile

    # Get user to author the settings in the properties files
    echo ".urls file successfully created.  Moving on to create properties file..."
    echo ""
    pause
    createPropFile
    echo ".prop file successfully created"

    # Login to daily motion
    echo ""
    echo "Preparing next stage..."
    initializeDailyMotion

    # Create usage file from uploads to account info
    [ -f "$allowanceFile" ] || rebuildAllowanceFile

    # Validate the setup before scheduling (schedule is checked on the startup checks anyway)
    validateSetup
    if [ $setupValidated != Y ]; then
        echo ""
        raiseError "First-Time-Setup NOT complete.  To start again, try the command --first-time-setup"
    fi

    # Create Cron Job Schedule
    echo ""
    echo ""
    echo ""
    echo "Last step is to setup this script to run automatically on schedule."
    echo "You will be moved to another file editor where you can override the randomly assigned minute/hour schedule"
    echo ""
    pause
    editCronFile

    # Confirm
    echo "First-time setup complete!"

}

validateSetup() {

    # Default response
    setupValidated=Y

    # Ensure urls file exists
    if ! [ -f "$urlsFile" ]; then
        setupValidated=N
        printError "urls file not found! $urlsFile"
        echo "Use the command --edit-urls to setup again"
    fi

    # Ensure properties file exists
    if ! [ -f "$propertiesFile" ]; then
        setupValidated=N
        printError "prop file not found! $propertiesFile"
        echo "Use the command --edit-prop to setup again"
    else
        # Ensure a refesh token exists
        dmRefreshToken=$(grep \
            --perl-regexp \
            --only-matching \
            '^dmRefreshToken=\K.*' \
            "$propertiesFile" \
        )
        if [ -z "$dmRefreshToken" ]; then
            setupValidated=N
            printError "Connection to dailymotion has not been confirmed!"
            echo "Try the command --grant-access to setup again"
        fi
    fi

    # Suggest to rerun the setup
    if [ $setupValidated = N ]; then
        echo "Alternatively run the command --first-time-setup to start from scratch"
    fi

}

loadPropertiesFile() {

    # Error if .prop file does not exist
    [ -f "$propertiesFile" ] || raiseError "Properties file not found! $propertiesFile"

    # Set the default properties
    #setDefaultPropteries
    # (Taken out.  If a user removes a required property it needs to fail)

    # Load properties from users set file
    . "$propertiesFile"
    [ $? -eq $ec_Success ] || raiseError "Failure occurred while loading .prop file: $propertiesFile"

    # Check for new template version of the properties file (and update if needed)
    updatePropFile || return 0

    # Validate the properties
    validateProperties

    # Print all the properties
    if [ $optDebug = Y ]; then
        echo "User's set Property values..."
        echo "processingDirectory:                  " $processingDirectory
        echo "keepDownloadedVideos:                 " $keepDownloadedVideos
        echo "youtubePlaylistReverse:               " $youtubePlaylistReverse
        echo "mirrorVideoThumbnails:                " $mirrorVideoThumbnails
        echo "delayDownloadIfVideoIsLongerThan:     " $delayDownloadIfVideoIsLongerThan
        echo "delayDownloadDuration:                " $delayDownloadDuration
        echo "delayedVideosWillBeUploadedAfter:     " $delayedVideosWillBeUploadedAfter
        echo "delayDownloadsAfter:                  " $(date -d @$delayDownloadsAfter)
        echo "targetRemainingAllowance:             " $targetRemainingAllowance
        echo "targetRemainingDuration:              " $targetRemainingDuration
        echo "durationAllowanceSearchTimeout:       " $durationAllowanceSearchTimeout
        echo "timeoutVideoDurationSearch:           " $timeoutVideoDurationSearch
        echo "uploadVideoAppendedTags:              " $uploadVideoAppendedTags
        echo "uploadVideoWithNextVideoIdPlayback:   " $uploadVideoWithNextVideoIdPlayback
        echo "uploadVideoWithPassword:              " $uploadVideoWithPassword
        echo "uploadVideoAsPrivate:                 " $uploadVideoAsPrivate
        echo "uploadVideoAsCountryCode:             " $uploadVideoAsCountryCode
        echo "uploadVideoInCategory:                " $uploadVideoInCategory
        echo "uploadVideoDescrTEMPLATE ..."
        echo "$uploadVideoDescrTEMPLATE"
        echo ""
    fi

}

validateProperties() {

    # Track Validation Failure
    propFailedValidation=N

    # Ensure processing directory exists
    if ! [ -z "$processingDirectory" ]; then
        if ! [ -d "$processingDirectory" ]; then
            printError "The processingDirectory \"$processingDirectory\" does not exist!"
            propFailedValidation=Y
        else
            processingDirectoryFull=$processingDirectory"/"
        fi
    fi

    # Validate Boolean expression for keeping videos
    if [ "$keepDownloadedVideos" != "Y" ] && [ "$keepDownloadedVideos" != "N" ]; then
        printError "\"$keepDownloadedVideos\" is an invalid boolean.  Expected Y or N on keepDownloadedVideos"
        propFailedValidation=Y
    fi

    # Validate Boolean expression for Playlist Reverse
    if [ "$youtubePlaylistReverse" != "Y" ] && [ "$youtubePlaylistReverse" != "N" ]; then
        printError "\"$youtubePlaylistReverse\" is an invalid boolean.  Expected Y or N on youtubePlaylistReverse"
        propFailedValidation=Y
    else
        youtubePlaylistReverseOpt=
        [ "$youtubePlaylistReverse" = "Y" ] && youtubePlaylistReverseOpt=Y
    fi

    # Validate Boolean expression for Mirror Thumbnails
    if [ "$mirrorVideoThumbnails" != "Y" ] && [ "$mirrorVideoThumbnails" != "N" ]; then
        printError "\"$mirrorVideoThumbnails\" is an invalid boolean.  Expected Y or N on mirrorVideoThumbnails"
        propFailedValidation=Y
    else
        mirrorVideoThumbnailsOpt=
        [ "$mirrorVideoThumbnails" = "Y" ] && mirrorVideoThumbnailsOpt=Y
    fi

    # Validate Boolean expression for uploading videos as private
    if [ "$uploadVideoAsPrivate" != "Y" ] && [ "$uploadVideoAsPrivate" != "N" ]; then
        printError "\"$uploadVideoAsPrivate\" is an invalid boolean.  Expected Y or N on uploadVideoAsPrivate"
        propFailedValidation=Y
    else
        uploadVideoAsPrivateOpt=
        [ "$uploadVideoAsPrivate" = "Y" ] && uploadVideoAsPrivateOpt=Y
    fi

    # Convert Delay Length Time to number
    if ! isDate "$delayDownloadIfVideoIsLongerThan"; then
        printError "\"$delayDownloadIfVideoIsLongerThan\" is an invalid time value for delayDownloadIfVideoIsLongerThan"
        propFailedValidation=Y
    else
        delayDownloadDuration=$(timeInSeconds "$delayDownloadIfVideoIsLongerThan")
        if ! [ $delayDownloadDuration -gt 0 ]; then
            printError "\"$delayDownloadIfVideoIsLongerThan\" is not a positive value for delayDownloadIfVideoIsLongerThan"
            propFailedValidation=Y
        fi
    fi

    # Convert Delay Period Time to number
    if ! isDate "$delayedVideosWillBeUploadedAfter"; then
        printError "\"$delayedVideosWillBeUploadedAfter\" is an invalid time value for delayedVideosWillBeUploadedAfter"
        propFailedValidation=Y
    else
        delayDownloadsAfter=$(date +%s -d "-$delayedVideosWillBeUploadedAfter")
    fi

    # Convert the target allowance to a number
    if ! isDate "$targetRemainingAllowance"; then
        printError "\"$targetRemainingAllowance\" is an invalid time value for targetRemainingAllowance"
        propFailedValidation=Y
    else
        targetRemainingDuration=$(timeInSeconds "$targetRemainingAllowance")
        if ! [ $targetRemainingDuration -gt 0 ]; then
            printError "\"$targetRemainingAllowance\" is not a positive value for targetRemainingAllowance"
            propFailedValidation=Y
        fi
    fi

    # Convert search timeout to a number
    if ! isDate "$durationAllowanceSearchTimeout"; then
        printError "\"$durationAllowanceSearchTimeout\" is an invalid time value for durationAllowanceSearchTimeout"
        propFailedValidation=Y
    else
        timeoutVideoDurationSearch=$(timeInSeconds "$durationAllowanceSearchTimeout")
        if ! [ $timeoutVideoDurationSearch -gt 0 ]; then
            printError "\"$durationAllowanceSearchTimeout\" is not a positive value for durationAllowanceSearchTimeout"
            propFailedValidation=Y
        fi
    fi

    # Ensure video category is valid
    testDailyMotionAvailablity
    dmServerResponse=$(curl --silent \
        https://api.dailymotion.com/channel/$uploadVideoInCategory
    )
    dmValidChannel=$(queryJson "id" "$dmServerResponse") || exit 1
    if [ "$dmValidChannel" = "null" ]; then
        printError "\"$uploadVideoInCategory\" is an invalid Channel for dailymotion.com on uploadVideoInCategory"
        propFailedValidation=Y
    fi

    # Ensure next video player is a valid video
    if ! [ -z "$uploadVideoWithNextVideoIdPlayback" ]; then
        dmServerResponse=$(curl --silent \
            https://api.dailymotion.com/video/$uploadVideoWithNextVideoIdPlayback
        )
        dmValidVideo=$(queryJson "id" "$dmServerResponse") || exit 1
        if [ "$dmValidVideo" = "null" ]; then
            printError "\"$uploadVideoWithNextVideoIdPlayback\" is an invalid video ID for dailymotion.com on uploadVideoWithNextVideoIdPlayback"
            propFailedValidation=Y
        fi
    fi

    # Validate country code
    if ! [ -z "$uploadVideoAsCountryCode" ]; then
        dmServerResponse=$(curl --silent \
            "https://api.dailymotion.com/users?country=$uploadVideoAsCountryCode"
        )
        dmValidCountry=$(queryJson "error" "$dmServerResponse") || exit 1
        if [ "$dmValidCountry" != "null" ]; then
            printError "\"$uploadVideoAsCountryCode\" is not a valid Country code on uploadVideoAsCountryCode"
            propFailedValidation=Y
        fi
    fi

    # Did any validations fail
    if ! [ $propFailedValidation = N ]; then

        # Prompt user to make change (when in interactive mode)
        if [ -t 0 ]; then
            echo ""
            echo "Validation failures found on your .prop file!"
            promptYesNo "Do you want to review and make changes now?"
            if ! [ $? -eq $ec_Yes ]; then
                echo ""
                echo "Run with the command --edit-prop to make changes later"
                raiseError "Quitting due to properties files validation failures"
            fi

            # Run command to edit the prop file
            editPropFile

        else

            # Exit with error
            raiseError "The .prop file failed validations!  Please use the --edit-prop command to correct"
        fi
    fi

}

createUrlsFile() {

    # Backup existing file
    if [ -f "$urlsFile" ]; then
        echo ".urls file already exists! $urlsFile"
        promptYesNo "This will overwrite your .urls files.  Would you like to skip this step?"
        [ $? -eq $ec_Yes ] && return 0
        echo ""
        echo "creating backup (.bku) copy just encase you change your mind..."
        cp "$urlsFile" "$urlsFile.bku"
    fi

    # Blank new urls file
    blankUrlsFile > "$urlsFile"

    # Allow user to make edits
    editUrlsFile

}

editUrlsFile() {

    # Open urls file for user edits
    nano --syntax=sh "$urlsFile"

}

blankUrlsFile() {

    echo "# ***** READ ME ******"
    echo "# Below is your urls file (.urls)"
    echo "# This holds the channel(s) or playlist(s) you want mirrored"
    echo "# Paste in all your urls addresses of any channel or playlist to mirror"
    echo "# Each url should be on it's own new line below."
    echo "# Once done, press Ctrl+X to exit, then type Y and hit Enter to save your changes"
    echo "# You can return to this screen at anytime using the command option:"
    echo "#     $scriptFile --edit-urls"
    echo "# ********************"
    echo ""
    echo ""

}

createPropFile() {

    # Backup existing file
    if [ -f "$propertiesFile" ]; then
        echo ".prop file already exists! $propertiesFile"
        promptYesNo "This will overwrite your .prop file. Would you like to skip this step?"
        [ $? -eq $ec_Yes ] && return 0
        echo "creating backup (.bku) copy just encase you change your mind..."
        cp "$propertiesFile" "$propertiesFile.bku"
    fi

    # Blank new prop file
    blankPropFile > "$propertiesFile"

    # Allow user to make edits
    editPropFile

}

editPropFile() {

    # Open prop file for user edits
    nano --syntax=awk "$propertiesFile"

    # Load and Validate the properties file
    echo "Validating any changes..."
    loadPropertiesFile

}

attemptedPropFileUpdate=N
updatePropFile() {

    # Is the version different?
    if [ "$propTemplateVersion" != "$propTemplateCurrentVersion" ]; then

        # Ensure this wasn't previously attempted
        [ $attemptedPropFileUpdate = Y ] && raiseError "Failed to update to latest prop file template!?"

        # Print info for user
        echo "Detected new template for the .prop file on latest version!"
        echo "Your .prop file version    " $propTemplateVersion
        echo "Latest .prop file version: " $propTemplateCurrentVersion
        echo "This may include new required preference settings"
        echo "Saving backup (.bku) file before making changes"
        echo ""

        # Attempt update (don't call the create procedure, because it tries to edit afterwards)
        attemptedPropFileUpdate=Y
        cp "$propertiesFile" "$propertiesFile.bku"
        blankPropFile > "$propertiesFile"

        # Reload properties to get newest values
        loadPropertiesFile

        # Return error to force previous call from loadPropertiesFile to move on
        return $ec_Error
    fi

}

setDefaultPropteries() {

    # Default Properties
    [ -z "$processingDirectory" ]                   && processingDirectory=
    [ -z "$keepDownloadedVideos" ]                  && keepDownloadedVideos=N
    [ -z "$youtubePlaylistReverse" ]                && youtubePlaylistReverse=N
    [ -z "$delayDownloadIfVideoIsLongerThan" ]      && delayDownloadIfVideoIsLongerThan="60 minutes"
    [ -z "$delayedVideosWillBeUploadedAfter" ]      && delayedVideosWillBeUploadedAfter="7 days"
    [ -z "$targetRemainingAllowance" ]              && targetRemainingAllowance="30 seconds"
    [ -z "$durationAllowanceSearchTimeout" ]        && durationAllowanceSearchTimeout="30 minutes"
    [ -z "$mirrorVideoThumbnails" ]                 && mirrorVideoThumbnails=N
    [ -z "$uploadVideoAppendedTags" ]               && uploadVideoAppendedTags=
    [ -z "$uploadVideoWithNextVideoIdPlayback" ]    && uploadVideoWithNextVideoIdPlayback=
    [ -z "$uploadVideoAsPrivate" ]                  && uploadVideoAsPrivate=N
    [ -z "$uploadVideoWithPassword" ]               && uploadVideoWithPassword=
    [ -z "$uploadVideoAsCountryCode" ]              && uploadVideoAsCountryCode=
    [ -z "$uploadVideoInCategory" ]                 && uploadVideoInCategory=
    [ -z "$uploadVideoDescrTEMPLATE" ]              && uploadVideoDescrTEMPLATE='$youtubeVideoDescr

Originally uploaded on $youtubeVideoUploadDate to:
$youtubeVideoLink

Subscribe on Youtube:
$youtubeChannel

$youtubeVideoTags'

}

propTemplateCurrentVersion=0.3
blankPropFile() {

    # Default Properties
    setDefaultPropteries

    # Create File
    echo "propTemplateVersion=$propTemplateCurrentVersion"
    echo "# ***** READ ME ******"
    echo "# Below is your properties file (.prop) to hold all your download/upload preferences"
    echo "# Each setting has a label followed by an equals sign (=) followed by your entry"
    echo "# There is a description above each setting's label"
    echo "# Note that some settings are marked as required, for which you MUST supply a value"
    echo "# Take the time to review these settings and make sure you are satisfied"
    echo "# Once done, press Ctrl+X to exit, then type Y and hit Enter to save your changes"
    echo "# You can return to this screen at anytime using the command option:"
    echo "#     $scriptFile --edit-prop"
    echo "# ********************"
    echo ""
    echo ""
    echo "# (optional) Processing directory (used to backup program files and process the"
    echo "#    downloaded files)"
    echo "processingDirectory=\"$processingDirectory\""
    echo ""
    echo ""
    echo "# (REQUIRED) Keep Downloaded videos? (Y or N)"
    echo "#    (If Yes, please ensure the the drive your using has adequate storage space!)"
    echo "keepDownloadedVideos=$keepDownloadedVideos"
    echo ""
    echo ""
    echo "# (REQUIRED) Reverse the Playlist's order when downloading (Y or N)"
    echo "#    (Change to 'Y' if you wand to mirror channel from the oldest video forward)"
    echo "youtubePlaylistReverse=$youtubePlaylistReverse"
    echo ""
    echo ""
    echo "# (REQUIRED) Live-stream identification and time to wait for video to be trimmed"
    echo "#    (the youtube-dl service does not provide identification of live streamed videos"
    echo "#    , so these settings are used to define which videos to considered live streams)"
    echo "#    1) Enter the minimum duration a video must be to considered a live-stream"
    echo "#    2) Enter how long to delay this videos' upload to wait for trimming"
    echo "delayDownloadIfVideoIsLongerThan=\"$delayDownloadIfVideoIsLongerThan\""
    echo "delayedVideosWillBeUploadedAfter=\"$delayedVideosWillBeUploadedAfter\""
    echo ""
    echo ""
    echo "# (REQUIRED) Upload Duration Allowance Target"
    echo "#    (The daily duration allowance to have remaining before the script quits)"
    echo "targetRemainingAllowance=\"$targetRemainingAllowance\""
    echo ""
    echo ""
    echo "# (REQUIRED) Timeout for the video duration search"
    echo "#   (Time to spend scanning for videos in your playlists' that can fit the remaining"
    echo "#   duration allowance before the script quits)"
    echo "durationAllowanceSearchTimeout=\"$durationAllowanceSearchTimeout\""
    echo ""
    echo ""
    echo "# (REQUIRED) Video Thumbnail Mirror (Y or N)"
    echo "#    (Note: requires a dailymotion partner account)"
    echo "mirrorVideoThumbnails=$mirrorVideoThumbnails"
    echo ""
    echo ""
    echo "# (optional) Append Tags to all uploaded videos (comma separated)"
    echo "#    (Note: existing youtube tags and hash tags will be also mirrored)"
    echo "uploadVideoAppendedTags=\"$uploadVideoAppendedTags\""
    echo ""
    echo ""
    echo "# (optional) Suggested dailymotion video id after playback ends"
    echo "#    (Note: requires a dailymotion partner account before it actually works)"
    echo "uploadVideoWithNextVideoIdPlayback=\"$uploadVideoWithNextVideoIdPlayback\""
    echo ""
    echo ""
    echo "# (REQUIRED) Set uploaded videos to private (Y or N)"
    echo "uploadVideoAsPrivate=$uploadVideoAsPrivate"
    echo ""
    echo ""
    echo "# (optional) Set password for viewing video"
    echo "uploadVideoWithPassword='$uploadVideoWithPassword'"
    echo ""
    echo ""
    echo "# (optional) Video Country Origin"
    echo "#    (Country Codes: https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2)"
    echo "uploadVideoAsCountryCode=\"$uploadVideoAsCountryCode\""
    echo ""
    echo ""
    echo "# (REQUIRED) Category to post all videos under"
    echo "#    (Also known as a 'Channel' on dailymotion.com) pick from the valid codes below"
    echo "uploadVideoInCategory=\"$uploadVideoInCategory\""
    echo "#  Valid codes: 'animals', 'kids', 'music', 'news', 'sport', 'tech', 'travel', 'tv',"
    echo "#               'webcam', 'auto' (aka Cars), 'people' (aka Celeb),"
    echo "#               'fun' (aka Comedy & Entertainment), 'creation' (aka Creative),"
    echo "#               'school' (aka Education), 'videogames' (aka Gaming)"
    echo "#               'lifestyle' (aka Lifestyle & How-to), 'shortfilms' (aka movies)"
    echo ""
    echo ""
    echo "# (REQUIRED) Description template for all uploaded videos"
    echo "uploadVideoDescrTEMPLATE='$uploadVideoDescrTEMPLATE'"
    echo ""
    echo "# Available substitutions for the video description above"
    echo "#   \$youtubeVideoDescr          = The full description from the youtube video"
    echo "#   \$youtubeVideoUploadDate     = Date the youtube video was uploaded"
    echo "#   \$youtubeVideoLink           = URL link to the youtube video"
    echo "#   \$youtubeChannel             = URL link to the youtube channel"
    echo "#   \$youtubeVideoTags           = All the tags from the youtube video"
    echo ""

    # Include API keys if set
    if ! [ -z "$dmRefreshToken" ]; then
        echo ""
        echo ""
        echo "# Dailymotion Authorised Account Access Keys"
        echo "dmApiKey=\"$dmApiKey\""
        echo "dmApiSecret=\"$dmApiSecret\""
        echo "dmRefreshToken=\"$dmRefreshToken\""
        echo ""
    fi

}

stopCronSchedule() {

    # Exit if no schedule exists
    [ -f "$cronJobFile" ] || raiseError "No cron schedule to stop"

    # Sudo Access required
    rootRequired

    # Delete the cron job file
    sudo rm $cronJobFile

}

editCronFile() {

    # Sudo Access required
    rootRequired

    # Edit in Temp file only
    tmpCronFile=$(mktemp)

    # Copy existing job
    if [ -f $cronJobFile ]; then
        cp $cronJobFile $tmpCronFile
    else
        # Create new cron file
        blankCronFile > $tmpCronFile
    fi

    # Edit the tmp file
    nano --syntax=awk $tmpCronFile

    # Copy to Cron Dir
    sudo cp $tmpCronFile $cronJobFile || exit 1
    sudo chmod 644 $cronJobFile || exit 1

    # Remove temp file
    rm $tmpCronFile

}

blankCronFile() {

    scheduleHour=$((RANDOM % 24))
    scheduleMinute=$((RANDOM % 60))
    echo ""
    echo "# Scheduled job for dailymotion upload (recommended to schedule once every 24 hours)"
    echo "$scheduleMinute $scheduleHour * * * $(whoami) \"$scriptDir/$scriptFile\" #--keep-log-file"
    echo ""
    echo "# Schedule format instructions..."
    echo "# [minute] [hour] [day-of-month] [month] [day-of-week] [user] [command-to-execute]"
    echo "# * * * * * user command"
    echo "# ┬ ┬ ┬ ┬ ┬"
    echo "# │ │ │ │ │"
    echo "# │ │ │ │ │"
    echo "# │ │ │ │ └─— day of week (0 - 7) (0 = Sun, 1 = Mon, etc, 6 = Sat, 7 = Sun)"
    echo "# │ │ │ └──── month (1 - 12)"
    echo "# │ │ └────── day of month (1 - 31)"
    echo "# │ └──────── hour (0 - 23)"
    echo "# └────────── min (0 - 59)"
    echo ""

}

updateSourceCode() {

    # Sudo Access required
    rootRequired

    # Print current version
    echo "Current version is $scriptVersionNo"

    # Use default branch?
    if [ -z "$optUpdateGitBranch" ]; then
        optUpdateGitBranch=$selfSourceCodeBranch
    else
        echo "You have selected to update to the '$optUpdateGitBranch' branch"
        echo "Please note that this is not the offical branch (update at your own risk!)"
    fi

    # Are you sure?
    promptYesNo "Are you sure you want update this script?"
    [ $? -eq $ec_Yes ] || exit

    # Compile source URL
    selfSourceCodeURL="$selfSourceCodeHost/$optUpdateGitBranch/$selfSourceCodeFile"

    # Download latest source code
    tmpFile=$(mktemp)
    wget --no-cache $selfSourceCodeURL --output-document $tmpFile
    if [ $? -ne $ec_Success ]; then
        raiseError "Failed to download the source code!?"
    fi

    # Get new version number
    newVersionNumber=$(grep \
        --perl-regexp \
        --only-matching \
        '^scriptVersionNo=\K.*' \
        "$tmpFile" \
    )

    # Cancel if already on newest version
    if [ "$scriptVersionNo" = "$newVersionNumber" ]; then
        rm $tmpFile
        raiseError "Nothing to update!  You are on the latest version $newVersionNumber"
    fi

    # Cancel if new version number is not greater
    if [ "$scriptVersionNo" \> "$newVersionNumber" ]; then
        echo "You are on a higher version than the latest $optUpdateGitBranch release!? Latest version is $newVersionNumber"
        promptYesNo "Are you sure you want downgrade this script?"
        if [ $? -ne $ec_Yes ]; then
            rm $tmpFile
            exit
        fi
    fi

    # Backup copy
    cp "$scriptDir/$scriptFile" "$scriptDir/$scriptFile.bku"

    # Copy to self
    mv $tmpFile "$scriptDir/$scriptFile"
    if [ $? -ne $ec_Success ]; then
        rm $tmpFile
        raiseError "Failed copy over the new source code!?"
    fi

    # Set correct permissions
    sudo chmod 755 "$scriptDir/$scriptFile"
    if [ $? -ne $ec_Success ]; then
        raiseError "Failed to set executable rights to the script file!?"
    fi

    # Success
    echo ""
    echo "Successfully updated code to the latest version number $newVersionNumber"

    # Update youtube-dl as well
    echo ""
    echo "Checking for updates to the youtube-dl service..."
    sudo $ytdl --update

}

testCodeDevONLY() {
    echo "nothing to test here :)"
}

# Start up program
arguments=$@
initialization
