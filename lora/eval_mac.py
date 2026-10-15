"""The phone's sixteen evaluation phrases, run on the Mac through the same template, tools and
prompts, so a training run can be scored before it goes near the phone.
Usage: python eval_mac.py <repo root> [adapter path]
"""
import re
import sys
from pathlib import Path

from mlx_lm import load, generate
from mlx_lm.sample_utils import make_sampler

ARGS = sys.argv[1:]
import importlib.util
spec = importlib.util.spec_from_file_location("gen_data", Path(__file__).with_name("gen_data.py"))
gen = importlib.util.module_from_spec(spec)
sys.argv = [sys.argv[0], ARGS[0], "/tmp/unused-eval-out"] + (["--tuned"] if "--tuned" in ARGS else [])
spec.loader.exec_module(gen)

EMAIL = ("Sam Rivera <sam@example.com>", "Q4 budget sheet",
         "Hi Raghav, could you look over the Q4 budget sheet before Thursday and send me your notes? "
         "The marketing line is the one I'm least sure about. Thanks, Sam", "")
CASES = [
    ("Can you label this Kilo Forge, please?", "label_current_email", "email"),
    ("Can you go ahead and archive this, please?", "archive_current_email", "email"),
    ("Reply saying I'll have it to you by Thursday, and send it.", "reply_to_current_email", "email"),
    ("What did they ask me to do?", None, "email"),
    ("Yeah, go ahead.", None, "email"),
    ("What is on my calendar for today?", "read_calendar", "email"),
    ("Okay, can you book, uh, two to 3:00 p.m. for me for massage, please?", "add_calendar_event", "email"),
    ("Can you cancel my lunch, please?", "cancel_calendar_event", "email"),
    ("There should be a block on my calendar from 12 to 1 for lunch. Can you cancel this for me, please?",
     "cancel_calendar_event", "email"),
    ("Uh, can you cancel my day and stand up at 4 p.m., please?", "cancel_calendar_event", "email"),
    ("Put this on my calendar for Thursday at 10.", "add_calendar_event", "email"),
    ("What do I have on Thursday?", "read_calendar", "open"),
    ("Add dentist tomorrow at 3.", "add_calendar_event", "open"),
    ("Cancel my 12 to 1 lunch today.", "cancel_calendar_event", "open"),
    ("Am I free tomorrow at 3?", "read_calendar", "open"),
    ("Is the dentist still on tomorrow?", "read_calendar", "open"),
]


def main():
    adapter = next((a for a in ARGS[1:] if not a.startswith("--")), None)
    import os
    model, tok = load(os.environ.get("MODEL", "mlx-community/gemma-4-e4b-it-4bit"), adapter_path=adapter, tokenizer_config={})
    sampler = make_sampler(temp=0.0)
    right = 0
    for phrase, expect, context in CASES:
        row = gen.exchange(context, phrase, [], EMAIL)
        prompt = tok.apply_chat_template(row["messages"], tools=row["tools"], add_generation_prompt=True, tokenize=False, enable_thinking=False)
        out = generate(model, tok, prompt=prompt, max_tokens=120, sampler=sampler, verbose=False)
        m = re.search(r"<\|tool_call>call:(\w+)\{(.*?)\}<tool_call\|>", out, re.S)
        picked = m.group(1) if m else None
        ok = picked == expect
        right += ok
        shown = f"{picked}{{{m.group(2)[:70]}}}" if m else "(no tool) " + out.strip()[:90].replace("\n", " ")
        print(f"{'✓' if ok else '✗'} {phrase[:60]:60s} → {shown}")
    print(f"score {right}/{len(CASES)}" + (f" with {adapter}" if adapter else " base"))


if __name__ == "__main__":
    main()
