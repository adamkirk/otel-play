import type { Metadata } from "next";
import { BasketProvider } from "@/components/basket";
import { Header } from "@/components/header";
import "./globals.css";

export const metadata: Metadata = {
  title: "Tea & Coffee Co.",
  description: "A toy shop for demoing OpenTelemetry",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className="h-full antialiased">
      <body className="flex min-h-full flex-col bg-stone-50 text-stone-900">
        <BasketProvider>
          <Header />
          <main className="mx-auto w-full max-w-5xl flex-1 px-4 py-8">{children}</main>
        </BasketProvider>
      </body>
    </html>
  );
}
