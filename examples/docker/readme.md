# Docker Example

This directory shows a very simple way of building a docker container to apply your database migrations.  This is not intended to be prod ready (passing environments etc) but just to get you started.

## Usage

Simply `docker-compose up` to:
- start a sql database server
- run the `grate` migration against the server with script locate in `db` folder and store the backup script in `output`

## Notes

- You wouldn't normally do db migrations using compose, this is just an example.

## Want to add more grate options

You can easily extend the support command using an entrypoint mount in Docker. You have 2 options below

### Option 1: Adding the additional flags when invoking the container (for example: warnandignoreononetimescriptchanges and verbosity)
```sh
docker run --rm -v $(pwd)/db:/db -v $(pwd)/output:/output erikbra/grate:latest --warnandignoreononetimescriptchanges=true --verbosity=Trace
```

### Option 2: Using a custom entrypoint script in a restricted environment (for example `my-entrypoint.sh`)
```sh
chmod +x my-entrypoint.sh
docker run --rm -v $(pwd)/db:/db -v $(pwd)/output:/output -v $(pwd)/my-entrypoint.sh:/app/entrypoint.sh erikbra/grate:latest
```