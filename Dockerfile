FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY index.js ./
COPY public ./public
ENV PORT=3847
EXPOSE 3847
CMD ["node", "index.js"]
