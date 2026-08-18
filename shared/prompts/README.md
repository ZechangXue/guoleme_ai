# Shared prompts

Prompt text and JSON schema used by both the Electron desktop app and the iOS companion app.

- Electron loads these files at runtime via `electron/sharedPrompts.ts` (with inlined fallbacks).
- iOS copies this folder into the app bundle and loads them via `PromptCatalog`.

Edit the `.txt` / `schema.json` files here — do not fork prompt wording in Swift or TypeScript unless you also update this folder.
