"""Training data for the on-device tool router: the same instructions, tools and prompt shapes the
app sends to the model, with gold tool calls computed in code. Writes train.jsonl and valid.jsonl in
mlx-lm chat format ({"messages": [...], "tools": [...]}). The sixteen evaluation phrases are held out.
"""
import json
import random
import re
import sys
from pathlib import Path

random.seed(20261014)
ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("data")
OUT.mkdir(parents=True, exist_ok=True)

NOW = "Now: Wednesday, October 14, 2026, 3:12 PM."
OFFLINE = (ROOT / "prompts/local-voice-offline.md").read_text().rstrip("\n")
inbox_src = (ROOT / "CodenameJo/Services/LocalVoice/LocalInbox.swift").read_text()
m = re.search(r'static let conversationInstructions = """\n(.*?)\n    """', inbox_src, re.S)
INBOX = "\n".join(line[4:] if line.startswith("    ") else line for line in m.group(1).split("\n"))
m2 = re.search(r'static let tunedInstructions = """\n(.*?)\n    """', inbox_src, re.S)
TUNED_INBOX = "\n".join(line[4:] if line.startswith("    ") else line for line in m2.group(1).split("\n"))
TUNED_OFFLINE = (ROOT / "prompts/local-voice-tuned.md").read_text().rstrip("\n")
TUNED = "--tuned" in sys.argv

HELD_OUT = {
    "Can you label this Kilo Forge, please?",
    "Can you go ahead and archive this, please?",
    "Reply saying I'll have it to you by Thursday, and send it.",
    "What did they ask me to do?",
    "Yeah, go ahead.",
    "What is on my calendar for today?",
    "Okay, can you book, uh, two to 3:00 p.m. for me for massage, please?",
    "Can you cancel my lunch, please?",
    "There should be a block on my calendar from 12 to 1 for lunch. Can you cancel this for me, please?",
    "Uh, can you cancel my day and stand up at 4 p.m., please?",
    "Put this on my calendar for Thursday at 10.",
    "What do I have on Thursday?",
    "Add dentist tomorrow at 3.",
    "Cancel my 12 to 1 lunch today.",
    "Am I free tomorrow at 3?",
    "Is the dentist still on tomorrow?",
}


def tool(name, description, props, order):
    return {"type": "function", "function": {"name": name, "description": description, "parameters": {
        "type": "object", "title": "Arguments", "properties": props, "required": order, "x-order": order,
        "additionalProperties": False}}}


def integer(description, lo, hi):
    return {"type": "integer", "description": description, "minimum": lo, "maximum": hi}


TOOLS = {
    "archive_current_email": tool(
        "archive_current_email", "Archives the email the user is looking at. Use when the user asks to archive it.",
        {"confirmed": {"type": "boolean", "description": "True when the user asked to archive the current email."}},
        ["confirmed"]),
    "reply_to_current_email": tool(
        "reply_to_current_email",
        "Writes a reply to the email the user is looking at: saves it as a Gmail draft, or sends it when the user said to send it.",
        {"body": {"type": "string", "description": "The reply text, written as the user, in plain text. No subject line."},
         "send": {"type": "boolean", "description": "True only when the user said to send the reply. False saves it as a draft."}},
        ["body", "send"]),
    "label_current_email": tool(
        "label_current_email",
        "Files the email the user is looking at under a Gmail label. Use when the user asks to label, file or tag it.",
        {"label": {"type": "string", "description": "The label name exactly as the user said it."}}, ["label"]),
    "read_calendar": tool(
        "read_calendar", "What is on the user's calendar on a day, or over the next few days.",
        {"dayOffset": integer("Days from today: 0 is today, 1 is tomorrow.", 0, 13),
         "days": integer("How many days to include from that day: 1 for that day only, 7 for a week.", 1, 7)},
        ["dayOffset", "days"]),
    "add_calendar_event": tool(
        "add_calendar_event",
        "Adds an event to the user's calendar. Use only when the user asked to add, schedule or block something and gave a day and a time.",
        {"title": {"type": "string", "description": "The event title, in the user's words."},
         "dayOffset": integer("Days from today: 0 is today, 1 is tomorrow.", 0, 30),
         "hour": integer("Start hour, 0 to 23.", 0, 23),
         "minute": integer("Start minute.", 0, 59),
         "durationMinutes": integer("Length in minutes; 60 when the user gave none.", 5, 480)},
        ["title", "dayOffset", "hour", "minute", "durationMinutes"]),
    "cancel_calendar_event": tool(
        "cancel_calendar_event",
        "Cancels an event on the user's calendar. Use only when the user asked to cancel, delete or remove one and named it.",
        {"dayOffset": integer("Days from today: 0 is today, 1 is tomorrow.", 0, 30),
         "title": {"type": "string", "description": "The event's name as the user said it, without the time or words like the or my."},
         "hour": integer("Start hour, 0 to 23, when the user said a time; -1 when they did not.", -1, 23)},
        ["dayOffset", "title", "hour"]),
}
EMAIL_TOOLS = ["archive_current_email", "reply_to_current_email", "label_current_email", "read_calendar",
               "add_calendar_event", "cancel_calendar_event"]
OPEN_TOOLS = ["read_calendar", "add_calendar_event", "cancel_calendar_event"]

EMAILS = [
    ("Sam Rivera <sam@example.com>", "Q4 budget sheet",
     "Hi Raghav, could you look over the Q4 budget sheet before Thursday and send me your notes? The marketing line is the one I'm least sure about. Thanks, Sam",
     "Sam wants your notes on the Q4 budget sheet before Thursday, especially the marketing line."),
    ("Priya Nair <priya@example.com>", "Offsite dates",
     "Hey, are you free the week of the 26th for the offsite? Mountain View or Tahoe, your call. Let me know by Friday. Priya",
     "Priya is asking whether you're free the week of the 26th for the offsite, Mountain View or Tahoe, and wants an answer by Friday."),
    ("Jordan Lee <jordan@example.com>", "Invoice 2231 overdue",
     "Hi, invoice 2231 for $4,800 was due on October 1 and is still open. Can you confirm when payment will go out? Jordan, Accounts",
     "Jordan says invoice 2231 for $4,800 was due October 1 and is still unpaid, and asks when payment will go out."),
    ("Dana Whitfield <dana@example.com>", "Re: Podcast intro",
     "Loved the draft. Two notes: cut the second paragraph, and can you mention the launch date? Need it back by tomorrow noon. Dana",
     "Dana liked the draft, wants the second paragraph cut and the launch date mentioned, and needs it back by tomorrow noon."),
    ("Chris Okafor <chris@example.com>", "Reference check",
     "Would you be willing to be a reference for Maya? The recruiter would call next week, about 15 minutes. Chris",
     "Chris is asking if you'll be a reference for Maya; the recruiter would call next week for about 15 minutes."),
    ("Noreply <billing@example.com>", "Your receipt from Cloudhost",
     "Thanks for your payment of $120.00 for Cloudhost Pro, October 2026. Receipt number 88213. No action needed.",
     "It's a receipt from Cloudhost for a $120 payment in October, nothing to do."),
    ("Alex Chen <alex@example.com>", "Standup moving to 9:30",
     "Heads up, standup moves to 9:30 starting Thursday so the London folks can join. Same room. Alex",
     "Alex says standup moves to 9:30 from Thursday so London can join, same room."),
]

WEEKDAYS = {"thursday": 1, "friday": 2, "saturday": 3, "sunday": 4, "monday": 5, "tuesday": 6, "next wednesday": 7}
DAY_PHRASES = [("today", 0), ("tomorrow", 1), ("tonight", 0), ("this afternoon", 0), ("tomorrow morning", 1),
               ("tomorrow afternoon", 1)] + [(f"on {w}", d) for w, d in WEEKDAYS.items()] + \
              [(f"{w}", d) for w, d in WEEKDAYS.items()] + [("next week", 7)]
SPOKEN_DAY = {0: "today", 1: "tomorrow", 2: "on Friday", 3: "on Saturday", 4: "on Sunday", 5: "on Monday",
              6: "on Tuesday", 7: "on October 21"}
EVENTS = ["lunch", "standup", "dentist", "team sync", "one on one with Sam", "gym", "haircut", "flight to Denver",
          "massage", "focus block", "call with Raghav", "board prep", "coffee with Priya", "vet appointment",
          "piano lesson", "investor call", "design review", "yoga", "lunch with Jordan", "dinner with Dana"]
FILLERS = ["", "", "", "Uh, ", "Um, ", "Okay, ", "Okay, uh, ", "So, ", "Hey Jo, ", "Jo, "]
ASKS = ["can you ", "could you ", "please ", "", "", "go ahead and ", "would you "]
TAILS = ["", "", ", please", " please", " for me", " for me, please", ", thanks"]


def clock(hour, minute):
    twelve = 12 if hour % 12 == 0 else hour % 12
    suffix = "AM" if hour < 12 else "PM"
    return f"{twelve} {suffix}" if minute == 0 else f"{twelve}:{minute:02d} {suffix}"


def time_phrase():
    """A spoken start time and the hour/minute it means. Bare hours 1 to 7 mean the afternoon."""
    kind = random.choice(["bare", "bare", "ampm", "ampm", "colon", "noon", "half", "oclock"])
    if kind == "noon":
        return random.choice(["at noon", "at 12", "at 12 p.m."]), 12, 0
    if kind == "half":
        h = random.randint(1, 11)
        return f"at half past {h}", (h + 12 if h <= 7 else h), 30
    if kind == "oclock":
        h = random.randint(1, 11)
        return f"at {h} o'clock", (h + 12 if h <= 7 else h), 0
    if kind == "bare":
        h = random.randint(1, 11)
        return f"at {h}", (h + 12 if h <= 7 else h), 0
    if kind == "colon":
        h, mnt = random.randint(1, 11), random.choice([15, 30, 45])
        ampm = random.choice(["", " a.m.", " p.m.", " am", " pm"])
        hour = h + 12 if ("p" in ampm or (ampm == "" and h <= 7)) else h
        return f"at {h}:{mnt:02d}{ampm}", hour, mnt
    h = random.randint(1, 11)
    ampm = random.choice(["a.m.", "p.m.", "am", "pm", "in the morning", "in the afternoon", "in the evening"])
    morning = ampm in ("a.m.", "am", "in the morning")
    return f"at {h} {ampm}", (h if morning else h + 12), 0


def span_phrase():
    """'from 2 to 3', 'two to 3:00 p.m.' and the hour, minute, duration they mean."""
    start = random.randint(1, 11)
    length = random.choice([1, 1, 1, 2, 0.5])
    end_h = start + int(length) if length >= 1 else start
    end_txt = f"{end_h}" if length >= 1 else f"{start}:30"
    words = {1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven", 8: "eight", 9: "nine",
             10: "ten", 11: "eleven"}
    style = random.choice(["digits", "digits", "words", "mixed"])
    s_txt = words[start] if style in ("words", "mixed") else str(start)
    ampm = random.choice(["", " p.m.", " pm", ":00 p.m."])
    hour = start + 12 if (start <= 7 or "p" in ampm) else start
    return f"from {s_txt} to {end_txt}{ampm}", hour, 0, int(length * 60), f"{s_txt} to {end_txt}{ampm}"


def duration_phrase():
    choice = random.choice([None, None, None, ("for an hour", 60), ("for half an hour", 30), ("for 30 minutes", 30),
                            ("for two hours", 120), ("for 45 minutes", 45), ("for an hour and a half", 90),
                            ("for 15 minutes", 15)])
    return choice


def noisy(text):
    """Speech-to-text texture: fillers, a dropped comma, a repeated word now and then."""
    text = random.choice(FILLERS) + text
    if random.random() < 0.12:
        words = text.split(" ")
        i = random.randrange(len(words))
        words.insert(i, words[i])
        text = " ".join(words)
    if random.random() < 0.5:
        text = text[0].upper() + text[1:]
    if not text.endswith(("?", ".", "!")):
        text += random.choice(["?", ".", "", "."])
    return text.replace("  ", " ")


def call(name, args):
    return {"role": "assistant", "content": "", "tool_calls": [{"type": "function", "function": {"name": name, "arguments": args}}]}


def exchange(context, phrase, turns, email=None):
    if context == "email":
        prompt = f"Current email data:\n<email>\nFrom: {email[0]}\nSubject: {email[1]}\nDate: Wed, 14 Oct 2026 09:12:00 -0400\n\n{email[2]}\n</email>\n{NOW}\nUser request: {phrase}"
        system, tools = (TUNED_INBOX if TUNED else INBOX), EMAIL_TOOLS
    else:
        prompt = f"{NOW}\n{phrase}"
        system, tools = (TUNED_OFFLINE if TUNED else OFFLINE), OPEN_TOOLS
    messages = [{"role": "system", "content": system}, {"role": "user", "content": prompt}] + turns
    return {"messages": messages, "tools": [TOOLS[t] for t in tools], "phrase": phrase}


def with_tool(name, args, result, final):
    return [call(name, args), {"role": "tool", "name": name, "content": result},
            {"role": "assistant", "content": final}]


def split(row):
    """One row per model turn, so the prompt mask covers exactly what the model did not write:
    (system, user) -> the tool call, and (..., tool call, tool result) -> the spoken line."""
    messages = row["messages"]
    calls = [i for i, m in enumerate(messages) if m.get("tool_calls")]
    if not calls:
        return [row]
    i = calls[0]
    first = dict(row, messages=messages[:i + 1])
    second = dict(row, messages=messages)
    return [first, second]


def read_result(offset, days):
    if days > 1:
        when = f"over the next {days} days" if offset == 0 else f"over the {days} days from {SPOKEN_DAY[offset].replace('on ', '')}"
    else:
        when = SPOKEN_DAY[offset]
    if random.random() < 0.3:
        return f"Nothing on your calendar {when}."
    count = random.randint(1, 3)
    items = random.sample(EVENTS, count)
    lines = ", and ".join(f"{e.capitalize()} at {clock(random.randint(8, 18), random.choice([0, 0, 30]))}" for e in items) \
        if count <= 2 else ", ".join(f"{e.capitalize()} at {clock(random.randint(8, 18), 0)}" for e in items[:-1]) + \
        f", and {items[-1].capitalize()} at {clock(random.randint(8, 18), 0)}"
    return f"{when[0].upper() + when[1:]} you have {'one thing' if count == 1 else f'{count} things'}: {lines}."


def gen_read(context, email):
    day, offset = random.choice(DAY_PHRASES)
    days = 7 if day == "next week" else 1
    if day == "next week":
        offset = 0 if random.random() < 0.5 else 7
    forms = [
        f"what's on my calendar {day}", f"what do I have {day}", f"what's on {day}", f"anything on my calendar {day}",
        f"what does {day} look like", f"am I free {day} {time_phrase()[0]}", f"do I have anything {day}",
        f"is the {random.choice(EVENTS)} still on {day}", f"when is my {random.choice(EVENTS)} {day}",
        f"how does my {day} look", f"read me my calendar for {day}", f"what's my schedule {day}",
        f"do I have any meetings {day}", f"what time is my {random.choice(EVENTS)} {day}",
    ]
    if days == 7:
        forms = ["what does my week look like", "what's on this week", "what do I have coming up this week",
                 "read me the week", "anything on next week", "what's my week look like"]
        offset = 7 if "next" in forms[0] else offset
    phrase = noisy(random.choice(forms))
    if days == 7 and "next" not in phrase.lower():
        offset = 0
    result = read_result(offset, days)
    return exchange(context, phrase, with_tool("read_calendar", {"dayOffset": offset, "days": days}, result, result), email)


def gen_add(context, email):
    title = random.choice(EVENTS)
    verb = random.choice(["add", "put", "schedule", "block", "book", "set up", "create", "hold"])
    day, offset = random.choice([d for d in DAY_PHRASES if d[0] != "next week"])
    if random.random() < 0.35:
        span, hour, minute, minutes, span_short = span_phrase()
        forms = [f"{verb} {title} {day} {span}", f"{verb} {span_short} {day} for {title}", f"{verb} {title} {span} {day}",
                 f"{verb} {span_short} for me for {title} {day}", f"block {span_short} {day} for {title}"]
    else:
        tp, hour, minute = time_phrase()
        dur = duration_phrase()
        minutes = dur[1] if dur else 60
        d_txt = f" {dur[0]}" if dur else ""
        forms = [f"{verb} {title} {day} {tp}{d_txt}", f"{verb} a {title} {tp} {day}{d_txt}",
                 f"put {title} on my calendar {day} {tp}{d_txt}", f"{verb} {title} {tp} {day}{d_txt}",
                 f"{verb} {title} to my calendar for {day} {tp}{d_txt}"]
        if verb == "put":
            forms = [f"put {title} on my calendar {day} {tp}{d_txt}", f"put a {title} on the calendar {tp} {day}{d_txt}"]
    phrase = noisy(random.choice(ASKS) + random.choice(forms) + random.choice(TAILS))
    args = {"title": title, "dayOffset": offset, "hour": hour, "minute": minute, "durationMinutes": minutes}
    dur_txt = {60: "an hour", 90: "an hour and a half", 120: "2 hours", 30: "30 minutes", 45: "45 minutes",
               15: "15 minutes"}.get(minutes, f"{minutes} minutes")
    result = f"Added {title}, {SPOKEN_DAY[offset]} at {clock(hour, minute)} for {dur_txt}."
    return exchange(context, phrase, with_tool("add_calendar_event", args, result, result), email)


def gen_add_from_email(email):
    """'Put this on my calendar Thursday at 10': the title comes from the email."""
    day, offset = random.choice([d for d in DAY_PHRASES if d[0] not in ("next week", "tonight")])
    tp, hour, minute = time_phrase()
    phrase = noisy(random.choice(ASKS) + random.choice([f"put this on my calendar {day} {tp}", f"add this to my calendar for {day} {tp}",
                                                        f"block time for this {day} {tp}", f"schedule this {day} {tp}"]) + random.choice(TAILS))
    title = email[1].replace("Re: ", "")
    args = {"title": title, "dayOffset": offset, "hour": hour, "minute": minute, "durationMinutes": 60}
    result = f"Added {title}, {SPOKEN_DAY[offset]} at {clock(hour, minute)} for an hour."
    return exchange("email", phrase, with_tool("add_calendar_event", args, result, result), email)


def gen_cancel(context, email):
    title = random.choice(EVENTS)
    verb = random.choice(["cancel", "cancel", "cancel", "delete", "remove", "scrap", "take off", "get rid of"])
    day, offset = random.choice([d for d in DAY_PHRASES if d[0] != "next week"])
    has_day = random.random() < 0.7
    d_txt = f" {day}" if has_day else ""
    if not has_day:
        offset = 0
    kind = random.choice(["name", "name", "name_time", "span", "time_only"])
    hour = -1
    if kind == "name":
        forms = [f"{verb} my {title}{d_txt}", f"{verb} the {title}{d_txt}", f"{verb} {title}{d_txt}",
                 f"{verb} my {title} off my calendar{d_txt}" if verb == "take off" else f"{verb} my {title}{d_txt}",
                 f"I need to {verb} the {title}{d_txt}", f"{title}{d_txt} is cancelled, {verb} it"]
        if verb == "take off":
            forms = [f"take my {title} off my calendar{d_txt}", f"take the {title}{d_txt} off the calendar"]
        if verb == "get rid of":
            forms = [f"get rid of the {title}{d_txt}", f"get rid of my {title} on the calendar{d_txt}"]
        spoken_title = title
    elif kind == "name_time":
        tp, hour, minute = time_phrase()
        forms = [f"{verb} my {title} {tp}{d_txt}", f"{verb} the {title}{d_txt} {tp}", f"{verb} {title} {tp}{d_txt}"]
        spoken_title = title
    elif kind == "span":
        span, hour, minute, minutes, span_short = span_phrase()
        forms = [f"{verb} my {span_short} {title}{d_txt}", f"there's a block {span}{d_txt} for {title}, {verb} it",
                 f"{verb} the {title} {span}{d_txt}"]
        spoken_title = title
    else:
        tp, hour, minute = time_phrase()
        forms = [f"{verb} my {tp[3:]}{d_txt}", f"{verb} my {tp[3:]} {random.choice(['meeting', 'appointment', 'thing'])}{d_txt}",
                 f"{verb} whatever I have {tp}{d_txt}"]
        spoken_title = tp[3:]
    phrase = noisy(random.choice(ASKS) + random.choice(forms) + random.choice(TAILS))
    args = {"dayOffset": offset, "title": spoken_title, "hour": hour}
    shown = clock(hour, 0) if hour >= 0 else clock(random.randint(9, 17), 0)
    result = f"Cancelled {title.capitalize()}, {SPOKEN_DAY[offset]} at {shown}."
    return exchange(context, phrase, with_tool("cancel_calendar_event", args, result, result), email)


def gen_archive(email):
    phrase = noisy(random.choice(ASKS) + random.choice(["archive this", "archive it", "archive this one", "archive that",
                                                        "archive this email", "file this away", "archive this, I'm done with it",
                                                        "just archive it"]) + random.choice(TAILS))
    return exchange("email", phrase, with_tool("archive_current_email", {"confirmed": True},
                                               "Archived. The next email will be presented. Say nothing more.", "Archived."), email)


LABELS = ["receipts", "Kiloforge", "Kilo Forge", "travel", "finance", "to read", "invoices", "personal", "hiring",
          "podcast", "follow up", "waiting", "Taxes 2026", "newsletters", "clients"]


def gen_label(email):
    label = random.choice(LABELS)
    phrase = noisy(random.choice(ASKS) + random.choice([f"label this {label}", f"label this as {label}", f"file this under {label}",
                                                        f"tag this {label}", f"put this under {label}", f"label it {label}",
                                                        f"file it under {label}", f"add the {label} label to this"]) + random.choice(TAILS))
    return exchange("email", phrase, with_tool("label_current_email", {"label": label}, f"Filed under {label}.",
                                               f"Filed under {label}."), email)


REPLY_BODIES = [
    ("I'll be there", "I'll be there."), ("yes, that works for me", "Yes, that works for me."),
    ("I'll have it to you by Friday", "I'll have it to you by Friday."), ("thanks, got it", "Thanks, got it."),
    ("let's do Tahoe", "Let's do Tahoe."), ("payment goes out Monday", "Payment goes out Monday."),
    ("happy to be a reference, have them call Tuesday", "Happy to be a reference. Have them call me on Tuesday."),
    ("no, I can't make it", "No, I can't make it."), ("sounds good, see you then", "Sounds good, see you then."),
    ("can we push it a week", "Can we push it a week?"),
]


def gen_reply(email):
    said, body = random.choice(REPLY_BODIES)
    send = random.random() < 0.5
    tail = random.choice([", and send it", " and send it", ", send it", ". Send that."]) if send else \
        random.choice(["", ", but don't send it", " as a draft", ", just draft it"])
    forms = [f"reply saying {said}{tail}", f"tell them {said}{tail}", f"reply {said}{tail}", f"write back {said}{tail}",
             f"draft a reply that says {said}{tail}", f"respond with {said}{tail}", f"say {said}{tail}"]
    phrase = noisy(random.choice(ASKS) + random.choice(forms))
    result = "Sent." if send else "Saved as a draft."
    return exchange("email", phrase, with_tool("reply_to_current_email", {"body": body, "send": send}, result, result), email)


def gen_question(email):
    q, a = random.choice([
        ("what did they ask me to do", email[3]), ("what's this about", email[3]), ("who is this from", f"It's from {email[0].split(' <')[0]}."),
        ("summarize this", email[3]), ("what do they want", email[3]), ("when do they need it by", email[3]),
        ("is there anything I need to do here", email[3]), ("read me the gist", email[3]),
        ("what's the subject", f"The subject is {email[1]}."),
    ])
    return exchange("email", noisy(q), [{"role": "assistant", "content": a}], email)


def gen_no_action(context, email):
    q, a = ("", "") if context == "open" else random.choice([
        ("yeah, go ahead", "Go ahead with what? Tell me what you'd like done with this email."),
        ("yes", "Yes to what? Tell me what you'd like done."),
        ("sure, do it", "Do what? Say what you'd like done with this email."),
        ("okay", "Okay. What would you like to do with this email?"),
        ("don't archive this", "Okay, I'll leave it in your inbox."),
        ("don't reply yet", "Okay, no reply for now."),
        ("should I reply to this", f"{email[3]} A short reply would cover it, if you want to send one."),
        ("I might cancel the dentist", "Okay. Say the word if you want it cancelled."),
        ("never mind", "Okay."),
        ("thanks", "You're welcome."),
        ("hmm, let me think", "Take your time."),
        ("what can you do here", "I can archive, label or reply to this email, and read, add or cancel calendar events."),
    ])
    if context == "open":
        q, a = random.choice([
            ("thanks", "You're welcome."), ("what can you do", "I can read your calendar, add an event or cancel one."),
            ("I might cancel the dentist", "Okay. Say the word if you want it cancelled."),
            ("don't add anything", "Okay, nothing added."), ("never mind", "Okay."),
            ("can you read my email", "Not here. Email is handled one message at a time when the call opens on your inbox."),
            ("what's the weather", "I can't reach the weather while everything stays on the phone, but I can read your calendar."),
            ("yeah, go ahead", "Go ahead with what? Tell me what you'd like done."),
        ])
    return exchange(context, noisy(q), [{"role": "assistant", "content": a}], email)


def gen_missing_time(context, email):
    title = random.choice(EVENTS)
    day, offset = random.choice([d for d in DAY_PHRASES if d[0] != "next week"])
    phrase = noisy(random.choice(ASKS) + random.choice([f"add {title} {day}", f"schedule {title} {day}", f"put {title} on my calendar {day}"]))
    return exchange(context, phrase, [{"role": "assistant", "content": f"What time {day} should I put {title}?"}], email)


def main():
    rows = []
    for _ in range(260):
        rows.append(gen_read("email", random.choice(EMAILS)))
        rows.append(gen_read("open", None))
    for _ in range(220):
        rows.append(gen_add("email", random.choice(EMAILS)))
        rows.append(gen_add("open", None))
    for _ in range(60):
        rows.append(gen_add_from_email(random.choice(EMAILS)))
    for _ in range(260):
        rows.append(gen_cancel("email", random.choice(EMAILS)))
        rows.append(gen_cancel("open", None))
    for _ in range(140):
        rows.append(gen_archive(random.choice(EMAILS)))
        rows.append(gen_label(random.choice(EMAILS)))
        rows.append(gen_reply(random.choice(EMAILS)))
        rows.append(gen_question(random.choice(EMAILS)))
    for _ in range(120):
        rows.append(gen_no_action("email", random.choice(EMAILS)))
        rows.append(gen_no_action("open", None))
    for _ in range(50):
        rows.append(gen_missing_time("email", random.choice(EMAILS)))
        rows.append(gen_missing_time("open", None))
    rows = [r for r in rows if r["phrase"] not in HELD_OUT]
    seen, unique = set(), []
    for r in rows:
        key = json.dumps(r["messages"][1]["content"]) + r["messages"][0]["content"][:20]
        if key in seen:
            continue
        seen.add(key)
        unique.append(r)
    random.shuffle(unique)
    valid_n = max(100, len(unique) // 12)
    written = {"valid": 0, "train": 0}
    with open(OUT / "valid.jsonl", "w") as f:
        for r in unique[:valid_n]:
            for part in split(r):
                f.write(json.dumps({"messages": part["messages"], "tools": part["tools"]}) + "\n")
                written["valid"] += 1
    with open(OUT / "train.jsonl", "w") as f:
        for r in unique[valid_n:]:
            for part in split(r):
                f.write(json.dumps({"messages": part["messages"], "tools": part["tools"]}) + "\n")
                written["train"] += 1
    print(f"{written['train']} train rows, {written['valid']} valid rows from {len(unique)} exchanges")


if __name__ == "__main__":
    main()
