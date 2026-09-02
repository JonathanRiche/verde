FROM oven/bun:1.4.0-alpine AS dependencies
WORKDIR /app/packages/connect_control_plane
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production

FROM oven/bun:1.4.0-alpine
WORKDIR /app/packages/connect_control_plane
ENV NODE_ENV=production
COPY --from=dependencies /app/packages/connect_control_plane/node_modules ./node_modules
COPY package.json ./package.json
COPY src ./src
COPY migrations ./migrations
COPY --from=control_plane_spec . /app/specs/control-plane/v1
USER bun
EXPOSE 8787
CMD ["bun", "src/main.ts"]
