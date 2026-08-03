import { connect } from "node:net";

if (process.argv[2] === "get") {
  const socketPath = process.env.GITHUB_CREDENTIAL_SOCKET ?? "/run/zhanlu-credentials/github.sock";
  let token = "";
  const socket = connect(socketPath);
  socket.on("data", (chunk) => { token += chunk.toString("utf8"); });
  socket.on("end", () => { if (!token.trim()) process.exit(1); process.stdout.write(`username=x-access-token\npassword=${token.trim()}\n`); });
  socket.on("error", () => process.exit(1));
}
