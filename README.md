# fx402

fx, with a wallet.

fx402 is a fork of [vercel-labs/fx](https://github.com/vercel-labs/fx), the tiny native coding agent written in Zig, with [x402](https://x402.org) payments built in. When an API returns HTTP 402, the agent reads the price, asks you for permission, pays in USDC on Base, and retries the request.

Payments are native tool calls compiled into the binary. There is no MCP server to spawn and no handshake before the agent can pay.

Website: [fx402.dev](https://www.fx402.dev)

## Install

```bash
curl -fsSL https://www.fx402.dev/setup.sh | bash
```

## What we added

Four tools:

- `x402_discover` · list the paid endpoints on an origin, with prices
- `x402_check` · read one endpoint's schema and exact price
- `x402_balance` · read the wallet's USDC balance on Base
- `x402_fetch` · pay for a request and return the response

When plain `web_fetch` hits a 402, it points the agent at `x402_fetch`.

## Your keys

- The wallet is generated once at `~/.fx/wallet.json` (mode 0600) and never overwritten.
- The private key never leaves your machine. The model never sees it.
- Every payment needs an explicit approval in the terminal. Without a TTY, fx402 refuses to spend.
- Payments are USDC on Base, signed with EIP-3009.

## Build from source

Requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/shafu0x/fx402.git
cd fx402
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

## Credit

All of the speed is [fx](https://github.com/vercel-labs/fx), built by the team at Vercel. This fork only adds the wallet.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
