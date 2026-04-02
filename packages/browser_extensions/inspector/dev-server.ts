import playground from "./playground/index.html";

const port = Number.parseInt(Bun.env.PORT ?? "0", 10);

const server = Bun.serve({
  port,
  routes: {
    "/": playground,
    "/playground": playground,
  },
  development: {
    hmr: true,
    console: true,
  },
});

console.log(`Verde inspector playground running at http://127.0.0.1:${server.port}`);
