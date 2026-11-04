#!/bin/bash
# Output in console and the containers will be removed if the script exits.
docker compose up --build && docker compose down