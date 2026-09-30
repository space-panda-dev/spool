# 0010. Names have one grammar and a length

Status: accepted

The protocol gives `task_id` and `capability` a grammar and gives `worker`
and `peer` none. The implementation fills the gap twice: a worker named as an
argument may hold no whitespace, and a worker named in a grant record may
hold no control character. A name passes through a shell argument, a file, a
JSON record, and a comparison that decides who owns a lease
([INV-5](../invariants.md)). Three things follow from leaving it open:

- A name outside ASCII reaches Spool through the locale. Under a locale that
  is not UTF-8 it arrives changed, and two names can arrive the same.
- A name that one rule accepts, the other refuses.
- No identifier has a length. A `task_id` of 230 characters is accepted by
  `put` and can never be leased, because the lease's file name is longer
  than a file name may be. `lease` stops at the first task it cannot move,
  so one such task, sorting first, stops every lease on the spool.

## Decision

`worker` has the grammar of `task_id`: ASCII letters, digits, `.`, `_`, and
`-`. It is 1 to 64 characters.

`peer` is a label for a person to read and is never compared or made into a
path. It is 1 to 128 characters, none of them a control character.

`task_id` and `capability` keep their grammars and gain a length: 1 to 128
characters each.

Each rule holds wherever the name is read: an argument, a line of input, a
grant record, a sidecar, a stored record. A name outside its rule is
malformed input from a caller (exit 2), a denied grant from a peer (exit 5),
and corrupt durable state in the spool's own files (exit 70).

A grant whose `worker` is outside the grammar stops working and is granted
again under a name inside it. A task already pending under an identifier
longer than 128 characters is corrupt durable state; its file is removed by
hand.

## Rejected

- Keep both worker rules: the same name is then valid or not by where it
  came from, and a lease taken under one cannot be named under the other.
- Any Unicode without whitespace: the name then depends on the locale of
  whoever typed it, and two names that look the same need not be.
- Unicode with normalisation: it adds a dependency and a second way for two
  spellings to be one name.
- The same grammar for `peer`: a label such as a person's name or a
  machine's description is what the field is for.
- Longer limits taken from the file system: the limit would differ by host,
  and a task put on one could not be leased on another.
