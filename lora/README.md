# Tool-routing adapter for Gemma 4 E4B

The on-device engine of a local call can run Gemma 4 E4B through MLX (see `LocalModel`). This
directory trains a LoRA adapter that teaches it Jo's six on-device tools and fuses it into a
4-bit checkpoint the phone loads from `Application Support/gemma-4-e4b-jo`.

```sh
uv venv --python 3.12 .venv && source .venv/bin/activate && uv pip install mlx-lm
python gen_data.py <repo root> data            # 2,400 exchanges, gold calls computed in code
python eval_mac.py <repo root>                 # the phone's 16 phrases on the untuned model
python train.py --model mlx-community/gemma-4-e4b-it-4bit --train --data data \
  --fine-tune-type lora --mask-prompt --num-layers 16 --batch-size 4 --iters 200 \
  --learning-rate 1e-4 --steps-per-eval 100 --val-batches 20 --max-seq-length 2048 \
  --grad-checkpoint --adapter-path adapters
python eval_mac.py <repo root> adapters        # score the adapter
python -m mlx_lm fuse --model mlx-community/gemma-4-e4b-it-4bit --adapter-path adapters \
  --save-path fused-gemma4-e4b-jo
xcrun devicectl device copy to --device <udid> --source fused-gemma4-e4b-jo \
  --destination "Library/Application Support/gemma-4-e4b-jo" --domain-type appDataContainer \
  --domain-identifier <bundle id>
```

`train.py` wraps `mlx_lm.lora` so the chat template renders with thinking off, which is how the
phone's bridge renders it. `gen_data.py` reads the live prompts from the repo and emits one row
per model turn, so the prompt mask covers exactly what the model did not write. The sixteen
evaluation phrases in `LocalToolEval` are held out of training.

`gen_data.py ... --tuned` renders the shorter prompts the app uses with a tuned model
(`prompts/local-voice-tuned.md`, `LocalInbox.tunedInstructions`); `eval_mac.py <root> <adapter>
--tuned` scores against them. The phone loads whichever of `gemma-4-e2b-jo` or `gemma-4-e4b-jo`
is present, the smaller first.

Measured 2026-10-14 on an M5 Max and an iPhone 17 Pro, 16 phrases:

| Model | Mac | Phone | Phone, tool turn |
|---|---|---|---|
| Apple AFM 3 Core Advanced | 9/16 | 9/16 | 4–5 s |
| Gemma 4 E4B untuned | 9/16 | 11/16 | 10–13 s |
| Gemma 4 E4B, 200-step adapter | 16/16 | 16/16 | 10–13 s |
| Gemma 4 E2B, same data | 16/16 | — | — |
| Gemma 4 E2B, short prompts | 16/16 | 16/16 | 3.8–5.1 s |

The phone timings are harness turns, which still include the model's second round after the tool;
a live call speaks the tool's line directly and skips that round.
