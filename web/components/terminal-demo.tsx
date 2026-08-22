import {
  AnimatedSpan,
  Terminal,
  TypingAnimation,
} from "@/components/ui/terminal";

const dim = "text-muted-foreground";

// Each pause stands in for real latency: the model thinking, the origin
// answering, the payment settling on Base.
const pause = (seconds: number) => ({ duration: 0.3, delay: seconds });

export function TerminalDemo() {
  return (
    <Terminal
      title="fx402"
      className="h-[380px] max-h-none w-full max-w-none overflow-hidden rounded-lg sm:h-[420px]"
    >
      <TypingAnimation duration={55}>
        {"> look up shafu0x on twitter"}
      </TypingAnimation>

      <AnimatedSpan transition={pause(0.7)}>
        <span>&nbsp;</span>
        <span>
          <span className={dim}>x402_discover</span> twit.sh
        </span>
      </AnimatedSpan>

      <AnimatedSpan className={dim} transition={pause(1)}>
        <span>&nbsp;&nbsp;GET /users/by/username · 0.005 USDC · x402</span>
        <span>&nbsp;&nbsp;GET /users/search · 0.01 USDC · x402</span>
        <span>&nbsp;&nbsp;33 more endpoints</span>
      </AnimatedSpan>

      <AnimatedSpan transition={pause(0.9)}>
        <span>&nbsp;</span>
        <span>
          <span className={dim}>x402_fetch</span>{" "}
          twit.sh/users/by/username?username=shafu0x
        </span>
        <span className="text-yellow-500/80">
          &nbsp;&nbsp;402 Payment Required
        </span>
      </AnimatedSpan>

      <AnimatedSpan transition={pause(0.7)}>
        <span>&nbsp;</span>
        <span>&nbsp;&nbsp;Pay 0.005 USDC on eip155:8453 to 0x8f3a…c21b</span>
        <span>
          &nbsp;&nbsp;for twit.sh/users/by/username? Wallet balance 4.982.
        </span>
        <span>&nbsp;</span>
      </AnimatedSpan>

      <AnimatedSpan transition={pause(0.4)}>
        <span>
          <span className="text-green-500/90">&nbsp;&nbsp;❯ Pay</span>
          <span className={dim}>
            &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Sign and retry with PAYMENT-SIGNATURE
          </span>
        </span>
        <span className={dim}>
          &nbsp;&nbsp;&nbsp;&nbsp;Cancel&nbsp;&nbsp;Do not pay
        </span>
        <span>&nbsp;</span>
      </AnimatedSpan>

      <AnimatedSpan className="text-green-500/90" transition={pause(1.5)}>
        <span>&nbsp;&nbsp;paid · 200 OK · 0.005 USDC · 1.2s</span>
        <span>&nbsp;</span>
      </AnimatedSpan>

      <TypingAnimation duration={30}>
        {"shafu0x · 14.2k followers · joined 2021 · building fx402"}
      </TypingAnimation>
    </Terminal>
  );
}
