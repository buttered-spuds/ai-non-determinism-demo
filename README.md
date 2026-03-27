# AI Non-Determinism Demo

An interactive demo that illustrates the non-deterministic nature of AI and large language model (LLM) responses, and the challenges this creates for automated testing.

## What this is

The demo simulates an AI assistant that responds to the same prompt differently each time — just as a real LLM would. It includes:

- A prompt simulator where the same input produces varied outputs depending on a temperature setting
- A hallucination demo showing how an AI can return subtly incorrect information even on factual questions
- A comparison of traditional assertion-based testing versus AI-aware semantic testing strategies
- A test strategy cheat sheet covering approaches such as semantic similarity scoring, LLM-as-a-judge, constraint-based assertions, and statistical testing
- A guide on how to automate testing against this kind of non-deterministic AI UI using Playwright

## What it helps you understand

AI outputs are non-deterministic: the same prompt can produce many different valid responses. This makes conventional test assertions (exact string matching) unreliable and prone to false failures. The demo makes this behaviour visible and tangible, and explains the testing strategies that actually work for AI systems.

## How to use it

Open `index.html` in any modern browser, or visit the hosted version at:

https://buttered-spuds.github.io/ai-non-determinism-demo/

No build step, no dependencies, and no backend — all responses are pre-written simulations running entirely in the browser.
