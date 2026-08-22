import { Heart } from "lucide-react";
import { TerminalDemo } from "@/components/terminal-demo";

const tools = [
  ["x402_discover", "list the paid endpoints on an origin, with prices"],
  ["x402_check", "read one endpoint's schema and exact price"],
  ["x402_balance", "read the wallet's USDC balance on Base"],
  ["x402_fetch", "pay for a request and return the response"],
];

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section className="mt-16">
      <h2 className="text-foreground text-[15px] font-semibold tracking-tight">
        {title}
      </h2>
      <div className="mt-4 space-y-3">{children}</div>
    </section>
  );
}

export default function Home() {
  return (
    <main className="mx-auto w-full max-w-2xl grow px-4 py-6 sm:px-7 sm:py-7">
      <nav className="flex items-center justify-between">
        <span className="font-semibold">
          <span className="italic">𝒇</span>x402
        </span>
        <div className="flex items-center gap-x-4 sm:gap-x-6">
          <a
            className="text-muted-foreground hover:text-foreground transition-colors"
            href="https://github.com/shafu0x/fx402"
          >
            source
          </a>
          <a
            className="text-muted-foreground hover:text-foreground transition-colors"
            href="https://fx.sh"
          >
            fx
          </a>
          <a
            className="text-muted-foreground hover:text-foreground transition-colors"
            href="https://x.com/shafu0x"
          >
            @shafu0x
          </a>
        </div>
      </nav>

      <div className="mt-10">
        <p>fx, with a wallet.</p>
        <p className="mt-4 break-all font-semibold">
          $ git clone https://github.com/shafu0x/fx402 &amp;&amp; zig build
        </p>
      </div>

      <div className="mt-10">
        <TerminalDemo />
      </div>

      <Section title="why">
        <p className="text-muted-foreground">
          fx is a 6mb coding agent that cold starts in 10µs. It is the fastest
          thing I have ever put in a terminal, and I used it for everything.
        </p>
        <p className="text-muted-foreground">
          Then it would hit a paywalled API and stop to ask me for a key. An
          agent that can read the entire internet and buy none of it is only
          half an agent. So I gave it a wallet.
        </p>
        <p className="text-muted-foreground">
          fx402 speaks{" "}
          <a
            className="text-foreground underline underline-offset-4"
            href="https://x402.org"
          >
            x402
          </a>
          , the open payment protocol built on HTTP 402. When the agent meets a
          paid endpoint it discovers the price, asks you, pays in USDC on Base,
          and keeps working. No keys, no accounts, no subscriptions.
        </p>
      </Section>

      <Section title="how it works">
        <p className="text-muted-foreground">
          Four tools, compiled into the binary. There is no MCP server to spawn
          and no handshake before the agent can pay.
        </p>
        <ul className="marker:text-muted-foreground list-disc space-y-1 pl-5">
          {tools.map(([name, description]) => (
            <li key={name}>
              {name}
              <span className="text-muted-foreground"> · {description}</span>
            </li>
          ))}
        </ul>
      </Section>

      <Section title="your keys">
        <ul className="text-muted-foreground marker:text-muted-foreground list-disc space-y-1 pl-5">
          <li>
            The wallet is generated once at{" "}
            <span className="text-foreground">~/.fx/wallet.json</span> and never
            overwritten.
          </li>
          <li>The private key never leaves your machine.</li>
          <li>
            Every payment needs an explicit approval in the terminal. Without a
            TTY, fx402 refuses to spend.
          </li>
          <li>Payments are USDC on Base, signed with EIP-3009.</li>
        </ul>
      </Section>

      <Section title="credit">
        <p className="text-muted-foreground">
          fx402 is a fork of{" "}
          <a
            className="text-foreground underline underline-offset-4"
            href="https://github.com/vercel-labs/fx"
          >
            vercel-labs/fx
          </a>
          , built by the team at Vercel. All of the speed is theirs. Apache-2.0.
        </p>
      </Section>

      <footer className="text-muted-foreground mt-20 flex items-center justify-center gap-x-1.5 border-t pt-6">
        <span>Built with</span>
        <Heart className="size-3.5" aria-label="love" />
        <span>by</span>
        <a
          className="text-foreground hover:underline hover:underline-offset-4"
          href="https://x.com/shafu0x"
        >
          shafu0x
        </a>
      </footer>
    </main>
  );
}
