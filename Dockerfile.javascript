# Use official minimal Node.js image
FROM node:20-slim

# Set working directory
WORKDIR /app

# Copy app files
COPY . .

