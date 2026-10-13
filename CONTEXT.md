# Buddy

A macOS cursor companion: you point at something on screen and Claude explains it next to your cursor.

## Language

### Asking

**Tap**:
Pressing fn⌃ together and releasing quickly; starts a circle-only request.
_Avoid_: Hotkey, shortcut press

**Hold**:
Keeping fn⌃ down past the tap threshold; starts a request that also listens for a spoken question.
_Avoid_: Push-to-talk, long press

**Drawing mode**:
The state in which the next mouse stroke becomes the circle.
_Avoid_: Overlay mode, selection mode

**Circle**:
The single freehand shape the user draws around what they're asking about, whatever its actual shape.
_Avoid_: Selection, highlight, annotation

**Spoken question**:
What the user said during a hold, sent as the question alongside the circle.
_Avoid_: Voice command, dictation, prompt

**Listening**:
The span during a hold in which the mic is on; it ends once the keys are released and the circle is finished, whichever is later, or at key release if no circle was started while an answer bubble is open (a follow-up).
_Avoid_: Recording

### Answering

**Answer bubble**:
The black bubble next to the cursor that shows listening, thinking, the answer and any follow-ups for one circle.
_Avoid_: Popup, tooltip, card

**Follow-up**:
A further question, typed or spoken, about the same circle while its answer bubble is open.
_Avoid_: Reply, second question
