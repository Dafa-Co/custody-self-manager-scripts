#!/bin/bash

# Step 1: Download the script to /tmp directory
SCRIPT_URL="https://raw.githubusercontent.com/Waer1/waer/refs/heads/master/run.sh"
SCRIPT_NAME="run.sh"
DOWNLOAD_PATH="/tmp/qqqq"
SCRIPT_FILE="$DOWNLOAD_PATH/$SCRIPT_NAME"

mkdir -p $DOWNLOAD_PATH

echo "Downloading the script from $SCRIPT_URL..."
curl -L -o "$DOWNLOAD_PATH/$SCRIPT_NAME" $SCRIPT_URL

# Check if the download was successful
if [ ! -f "$DOWNLOAD_PATH/$SCRIPT_NAME" ]; then
    echo "Failed to download the script. Exiting."
    exit 1
fi

# Step 2: Make the script executable
chmod +x "$SCRIPT_FILE"

# Step 3: Run the downloaded script and capture the user input
echo "Running the script..."
bash $SCRIPT_FILE 4
