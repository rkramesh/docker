# Aliases for basic terminal commands

# Clear the terminal screen
alias c="clear"

# Docker Compose Aliases
alias dcu="docker-compose up -d"         # Start containers in detached mode
alias dcd="docker-compose down"          # Stop and remove containers, networks, and volumes
alias dsp="docker system prune -af"      # Remove all unused Docker objects (containers, networks, volumes, images)
alias dps="docker ps -a"                 # List all containers, including stopped ones
alias drmi="docker image prune -a -f"    # Remove all unused Docker images


# Docker Exec: Execute a command inside a running container
dexec() {
  if [ -z "$2" ]; then
    # If no second argument, attempt to open bash or fallback to sh
    docker exec -it "$1" /bin/bash || docker exec -it "$1" /bin/sh
  else
    # Run the command passed as $2 inside the container
    docker exec -it "$1" "$2"
  fi
}

# Docker Kill: Stop and remove a container and its associated volumes
dkill() {
  if [ -z "$1" ]; then
    echo "Please provide the container name or ID"
    return 1
  fi

  # Stop the container
  docker stop "$1"

  # Remove the container
  docker rm "$1"

  # Remove dangling volumes
  docker volume ls -qf "dangling=true" | xargs -r docker volume rm

  echo "Container $1 and
