FROM node:20-alpine as build

WORKDIR /app

# Copy package files
COPY package.json package-lock.json ./

# Install dependencies
RUN npm ci

# Copy source
COPY . .

# Build webpack bundle
RUN npm run build

# Production stage
FROM nginx:alpine

# Copy all static files needed by miniPaint
COPY --from=build /app/index.html /usr/share/nginx/html/
COPY --from=build /app/dist /usr/share/nginx/html/dist
COPY --from=build /app/images /usr/share/nginx/html/images
COPY --from=build /app/src/css /usr/share/nginx/html/src/css

# Copy nginx config
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
