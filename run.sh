#!/bin/bash

# Function to check if Docker is installed
check_docker_installed() {
    if ! command -v docker &>/dev/null; then
        echo "Docker is not installed."
        return 1
    else
        echo "Docker is already installed."
        return 0
    fi
}

# Function to install Docker
install_docker() {
    echo "Starting Docker installation..."
    curl -o install-docker.sh https://releases.rancher.com/install-docker/24.0.sh
    sh install-docker.sh
    rm install-docker.sh
    if command -v docker &>/dev/null; then
        echo "Docker installation completed successfully."
    else
        echo "Docker installation failed. Please install Docker manually."
        exit 1
    fi
}

# Check if Docker is installed, prompt for installation if not
check_docker_installed || {
    echo "Docker is required. Do you want to install Docker? (yes/no)"
    read install_choice
    if [ "$install_choice" == "yes" ]; then
        install_docker
    else
        echo "Cannot proceed without Docker."
        exit 1
    fi
}

# Function to write environment variables to the .env file
write_to_env_file() {
    echo "$1=$2" >>.env
}

clear_env_file() {
    if [ -f .env ]; then
        > .env
    fi
}

get_bucket_name_and_region_from_url() {
    local aws_url=$1
    local bucket_name bucket_region

    aws_vs_do=$(echo "$aws_url" | grep -oP '(digitaloceanspaces|amazonaws)(?=\.com)')

    if [ "$aws_vs_do" == "amazonaws" ]; then
        bucket_region=$(echo "$aws_url" | grep -oP '\.([a-z0-9-]+)\.amazonaws\.com' | grep -oP '[a-z0-9-]+(?=\.amazonaws\.com)')
        bucket_name=$(echo "$aws_url" | grep -oP "https://\K(.*?)(?=\.s3\.$bucket_region\.amazonaws\.com)")
        aws_endpoint="https://s3.$bucket_region.amazonaws.com"
    elif [ "$aws_vs_do" == "digitaloceanspaces" ]; then
        bucket_region=$(echo "$aws_url" | grep -oP '\.([a-z0-9-]+)\.digitaloceanspaces\.com' | grep -oP '[a-z0-9-]+(?=\.digitaloceanspaces\.com)')
        bucket_name=$(echo "$aws_url" | grep -oP "https://\K(.*?)(?=\.$bucket_region\.digitaloceanspaces\.com)")
        aws_endpoint="https://$bucket_region.digitaloceanspaces.com"
    else
        echo "Invalid url." >&2
        echo "-1"
        exit 1
    fi

    # Validate bucket name (length > 2, no spaces)
    if [[ ${#bucket_name} -le 2 || "$bucket_name" =~ [[:space:]] ]]; then
        echo "Invalid url." >&2
        echo "-1"
        exit 1
    fi
    # Validate region (length > 0, contains only valid characters)
    if [[ -z "$bucket_region" || ! "$bucket_region" =~ ^[a-z0-9-]+$ ]]; then
        echo "Invalid url." >&2
        echo "-1"
        exit 1
    fi

    echo "$bucket_name $bucket_region $aws_endpoint"
}

# Function to collect and write AWS credentials
configure_aws_s3() {
    echo "Configuring AWS S3..."
    while true; do
        read -p "Enter AWS URL (e.g. https://bucket-name.s3.us-west-1.amazonaws.com/photos/image.jpg or https://my-space.nyc3.digitaloceanspaces.com/photos/image.jpg): " aws_url

        result=$(get_bucket_name_and_region_from_url "$aws_url")

        if [ "$result" != "-1" ]; then
            read -p "Enter Access Key Id: " bucket_key
            read -p "Enter Access Key Secret: " bucket_secret

            bucket_name=$(echo "$result" | awk '{print $1}')
            bucket_region=$(echo "$result" | awk '{print $2}')
            aws_endpoint=$(echo "$result" | awk '{print $3}')

            write_to_env_file "AWS_ENDPOINT" "$aws_endpoint"
            write_to_env_file "BUCKETKEY" "$bucket_key"
            write_to_env_file "BUCKETSECRET" "$bucket_secret"
            write_to_env_file "BUCKETREGION" "$bucket_region"
            write_to_env_file "BUCKETNAME" "$bucket_name"
            write_to_env_file "HANDLER" "amazonS3"

            docker_image="roxcustody/amazons3"
            break
        fi
    done
}

# Function to configure OneDrive or Google Drive with credentials file
configure_drive() {
    local service_name=$1
    local handler_value=$2
    echo "Configuring $service_name..."

    while true; do
        read -p "Enter the full path to your $service_name credentials.json: " drive_path
        drive_path="${drive_path/#\~/$HOME}" # Expand ~ to home directory
        if [[ -f "$drive_path" ]]; then
            cp "$drive_path" "$(dirname "$0")/credentials.json"
            echo "Credentials copied to script's directory."
            write_to_env_file "HANDLER" "$handler_value"
            file_to_mount="credentials.json"
            docker_image="roxcustody/${handler_value}"
            break
        else
            echo "File not found. Please enter a valid path."
        fi
    done
}

# Function to collect and write Dropbox credentials
configure_dropbox() {
    echo "Configuring Dropbox..."
    read -p "Enter Dropbox Access Token: " dropbox_access_token
    read -p "Enter Dropbox Client ID: " dropbox_client_id
    read -p "Enter Dropbox Client Secret: " dropbox_client_secret

    write_to_env_file "DROPBOX_ACCESS_TOKEN" "$dropbox_access_token"
    write_to_env_file "DROPBOX_CLIENT_ID" "$dropbox_client_id"
    write_to_env_file "DROPBOX_CLIENT_SECRET" "$dropbox_client_secret"
    write_to_env_file "HANDLER" "dropbox"

    file_to_mount=".env"
    docker_image="roxcustody/dropbox"
}

# Function to display storage options and get user choice

display_options() {

    local choice=$1 # Use the first argument as the choice

    if [ -z "$choice" ]; then
        # If no argument is passed, prompt the user
        echo "Please choose an option:"
        echo "1) AWS S3"       # .env
        echo "2) One Drive"    # credentials.json
        echo "3) Google Drive" # credentials.json
        echo "4) Dropbox"      # .env
        read -p "Enter your choice (1-4): " choice
    fi

    case $choice in
    1) configure_aws_s3 ;;
    2) configure_drive "OneDrive" "oneDrive" ;;
    3) configure_drive "Google Drive" "googleDrive" ;;
    4) configure_dropbox ;;
    *)
        echo "Invalid choice. Please select between 1 and 4."
        exit 1
        ;;
    esac
}

clear_env_file
display_options "$1"


# Function to find an available port
find_available_port() {
    for port in {3000..65535}; do
        if ! nc -z localhost $port; then
            echo $port
            return 0
        fi
    done
    echo "No available port found in range 3000-65535."
    exit 1
}

# Prompt for domain/IP and validate it
validate_domain_or_ip() {
    local input=$1
    if [[ "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$input" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,6}$ ]]; then
        return 0
    else
        echo "Invalid domain or IP format. Please try again."
        return 1
    fi
}

# Get and validate domain/IP
while true; do
    read -p "Enter the IP or domain of this machine: " user_domain
    validate_domain_or_ip "$user_domain" && break
done

read -p "Enter your RoxCustody's subdomain (your_subdomain.roxcustody.io): " corporate_subdomain
read -p "Enter your self custody manager (SCM) key: " api_key

# Write essential environment variables to .env
write_to_env_file "API_KEY" "$api_key"
write_to_env_file "DOMAIN" "$user_domain"

# Automatically select an available port
user_port=$(find_available_port)

write_to_env_file "PORT" "3000"
write_to_env_file "URL" "http://$user_domain:$user_port"
write_to_env_file "CUSTODY_URL" "https://${corporate_subdomain}.api-custody.roxcustody.io/api"


# Add randomization using a random string or timestamp
random_suffix=$(date +%s | sha256sum | base64 | head -c 8) # Generate an 8-character random string

# Generate custom Docker image and container names
image_name="${corporate_subdomain//./_}_image" # Replace dots in domain with underscores
sanitized_docker_image="${docker_image//\//_}_${random_suffix}"
container_name="${corporate_subdomain//./_}_${sanitized_docker_image}"


# Build the Docker container with the necessary files copied in
prepare_docker_image() {
    local base_image=$1
    local env_file=".env"
    local credentials_file=$2

    # Start a temporary container
    temp_container_id=$(docker create "$base_image")

    # Copy .env and credentials file into the temporary container
    docker cp "$env_file" "$temp_container_id:/usr/src/app/.env"

    if [ -n "$credentials_file" ]; then
        docker cp "$credentials_file" "$temp_container_id:/usr/src/app/$credentials_file"
    fi

    # Commit the container to a new image with the copied files
    docker commit "$temp_container_id" "$image_name"

    # Remove the temporary container and delete the .env file from host
    docker rm "$temp_container_id"
    rm "$env_file"
}

# pull the latest version of the base image
docker pull "$docker_image"

# Prepare the Docker image with the necessary environment variables
prepare_docker_image "$docker_image" "$file_to_mount"

# Remove credentials.json if it was copied to the script's directory
if [ "$file_to_mount" == "credentials.json" ]; then
    rm "$(dirname "$0")/credentials.json"
fi

# Run the Docker container from the newly created image with the custom name
echo "Running the application on $user_domain:$user_port with container name: $container_name..."
docker run -d -p $user_port:3000 --name "$container_name" "$image_name"
echo "Container is running on port $user_port with the necessary files copied inside."

# Print instructions to manage the container
echo -e "\n--- Docker Container Management Instructions ---"
echo "To view the container logs: docker logs $container_name -f"
echo "To stop the container: docker stop $container_name"
echo "To start the container again: docker start $container_name"
echo "To remove the container: docker rm $container_name"
echo "To remove the image: docker rmi $image_name"
