# Dockerfile for production Next.js app using Yarn (host-built output)
FROM node:18-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV YARN_CACHE_FOLDER=/tmp/.cache/yarn
RUN yarn cache clean && yarn install --production
COPY .next ./.next
COPY public ./public
EXPOSE 3000
CMD ["sh", "-c", "yarn start 2>&1"]
