#!/usr/bin/env bash

# Run the pre-built Oracle Sakila image from Docker Hub.
docker run -p 1521:1521 -d sakiladb/oracle:latest
