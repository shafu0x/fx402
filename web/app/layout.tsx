import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "fx402 - fx, with a wallet",
  description:
    "A fork of fx, the tiny native coding agent, with x402 payments built in. It discovers paid endpoints, asks before it spends, and pays in USDC on Base.",
  openGraph: {
    title: "fx402 - fx, with a wallet",
    description:
      "A fork of fx with x402 payments built in. Your agent can pay for the internet.",
    url: "https://fx402.vercel.app",
    siteName: "fx402",
  },
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
