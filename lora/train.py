"""mlx_lm.lora with the chat template rendered the way the phone renders it: thinking off.
Usage: python train.py <mlx_lm lora arguments>
"""
import sys

import mlx_lm.lora as lora
from mlx_lm.utils import load as real_load


def load_thinking_off(*args, **kwargs):
    model, tokenizer = real_load(*args, **kwargs)
    original = tokenizer.apply_chat_template

    def apply(*a, **k):
        k["enable_thinking"] = False
        return original(*a, **k)

    tokenizer.apply_chat_template = apply
    return model, tokenizer


lora.load = load_thinking_off
sys.argv = [sys.argv[0]] + sys.argv[1:]
lora.main()
