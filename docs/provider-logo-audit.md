# Provider Logo Trademark Audit

Date: 2026-04-21 (expanded pass)
Scope: provider logos in iOS model picker
Policy: show local logos only when we have source-backed permission language that covers third-party trademark/logo usage. Otherwise fallback to monogram.

## OpenRouter check (requested)

Yes — OpenRouter does render provider logos.

Observed icon endpoints on `openrouter.ai`:
- `/images/icons/Anthropic.svg`
- `/images/icons/OpenAI.svg`
- `/images/icons/GoogleGemini.svg`
- `/images/icons/GoogleVertex.svg`
- `/images/icons/Bedrock.svg`
- `/images/icons/Microsoft.svg`
- `/images/icons/Perplexity.svg`

Important: this confirms OpenRouter’s behavior, **not** that we automatically inherit trademark permission.

## Decision summary

Approved and currently shown with local assets:
- `openai`
- `mistral`
- `github-copilot`
- `huggingface`
- `vercel-ai-gateway`

Fallback monogram (not approved or no auditable permission/asset path yet):
- `amazon-bedrock`, `anthropic`, `azure-openai-responses`, `cerebras`, `google`, `google-antigravity`, `google-gemini-cli`, `google-vertex`, `groq`, `kimi-coding`, `lmstudio`, `minimax`, `minimax-cn`, `ollama`, `opencode`, `opencode-go`, `openrouter`, `openai-codex`, `xai`, `zai`, `omlx`

## Evidence excerpts (key)

### OpenAI
Source: https://openai.com/brand/ (captured via `r.jina.ai` mirror for auditing)
- “These guidelines are intended to help … third parties understand how to use and display our trademarks…”
- “By using our logos, you agree to our Marks usage terms.”
- “Only use our Marks if they adhere to these brand guidelines.”

Implementation source asset:
- Official OpenAI brand page media asset (`images.ctfassets.net`): `Blossom_Light.svg`

### Mistral
Source: https://mistral.ai/brand
- “We invite our friends and partners to utilize the Mistral AI logo in their materials…”
- Includes downloadable brand kit.

Implementation source asset:
- Official brand kit zip: `https://mistral.ai/static/branding/mistral-brand-assets.zip`
- Icon extracted from kit: `mistral-brand-assets/m/m-black.svg`

### GitHub / Copilot
Source: https://brand.github.com/foundations/logo
- Explicit permitted uses and restrictions are published.

Implementation source asset:
- GitHub-hosted favicon SVG.

### Hugging Face
Source: https://huggingface.co/brand
- Brand assets page publishes downloadable logos/assets.

Implementation source asset:
- Hugging Face-hosted logo SVG.

### Vercel
Source: https://vercel.com/geist/brands
- “You may use the Vercel marks to truthfully describe the products, services, and technologies that we offer.”
- Restriction set is also explicit.

Implementation source asset:
- Vercel-hosted design asset SVG.

## Examples of explicit disallow / restricted use

### Groq
Source: https://groq.com/trademark-policy
- “Except for limited nominative fair use, you must not use Groq Marks without prior written permission…”
- “Use Groq logos in ads, packaging, UI, or signage without a license from Groq.” (prohibited)

### AWS
Source: https://aws.amazon.com/trademark-guidelines/
- Third-party fair use is described as plain text only (no logos) unless licensed.

Source: https://aws.amazon.com/co-marketing/
- AWS offers specific “Powered by AWS” logos under trademark-guideline compliance.
- This does not automatically grant use of arbitrary AWS/Bedrock logo marks.

### Azure
Source: https://learn.microsoft.com/en-us/azure/architecture/icons/
- Azure icon terms are scoped to architecture diagrams/training/documentation usage.

## Notes on unresolved providers

- `anthropic`: official Brandfolder exists and states official/publicly accessible assets with usage guidance, but we do not yet have a stable, reproducible direct logo asset URL in this automation pass.
- `xai`: brand-guidelines text is explicit about logo terms and references a download link, but that link is not retrievable in this headless audit path yet.
- `openrouter`: no explicit public trademark/logo permission policy was captured in this pass.

## Current implementation outcome

Only approved providers above render local logos; all others continue to render monogram fallback.
