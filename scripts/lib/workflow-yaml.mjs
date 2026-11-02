// SPDX-License-Identifier: MIT
//
// A line reader for the hand-written workflows of this repository (two-space block YAML). It is not a
// YAML parser: check-workflows treats every construct it cannot read as an error, so nothing can hide
// from the checks in a flow mapping, an anchor or a quoted key. Shared by check-workflows.mjs and
// review-bot.mjs.

/** Splits a line at the first # outside quotes that starts a comment. */
function splitComment(line) {
    let quote = null;
    for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if (quote) {
            if (c === quote) quote = null;
        } else if (c === '"' || c === "'") {
            quote = c;
        } else if (c === "#" && (i === 0 || /\s/.test(line[i - 1]))) {
            return [line.slice(0, i).trimEnd(), line.slice(i + 1).trim()];
        }
    }
    return [line.trimEnd(), ""];
}

/**
 * Constructs this reader cannot follow, so the checks could not see a uses, if or permissions hidden in
 * them: flow mappings, flow sequences holding mappings or written for steps / jobs, quoted keys, anchors,
 * aliases and tags, and any line that is neither "key: value" nor "- scalar". Empty {} and [] hide nothing.
 */
function unsupported(line, m) {
    const v = line.value;
    if (!m) {
        if (/^\s*(?:-\s+)?(["']).*?\1\s*:/.test(line.code)) return "quoted keys are not supported";
        const item = /^\s*-\s+(.+)$/.exec(line.code);
        if (!item) return "unrecognized construct";
        return /^[{[&*!]/.test(item[1].trim()) ? "list items cannot be flow collections, anchors, aliases or tags" : null;
    }
    if (v === "{}" || v === "[]") return null;
    if (/^[{&*!]/.test(v)) return "flow mappings, anchors, aliases and tags are not supported";
    if (v.startsWith("[") && (/[{:]/.test(v) || line.key === "steps" || line.key === "jobs")) {
        return "flow sequences may only hold scalars";
    }
    return null;
}

/**
 * Splits text into { no, indent, key, value, comment, code, raw, bad }. Lines of a block scalar (deeper
 * lines after `run: |`) are marked { scalar: <key> } instead. For a list item `- key: v` indent is the
 * column of the key.
 */
export function workflowLines(text) {
    const out = [];
    let block = null; // { indent, key }
    text.split(/\r?\n/).forEach((raw, i) => {
        const indent = raw.match(/^ */)[0].length;
        if (block) {
            if (!raw.trim() || indent > block.indent) {
                out.push({ no: i + 1, indent, scalar: block.key, raw });
                return;
            }
            block = null;
        }
        if (!raw.trim() || raw.trim().startsWith("#")) return;
        const [code, comment] = splitComment(raw);
        const m = /^(\s*)(-\s+)?([A-Za-z0-9_-]+):(?:\s+(.*))?$/.exec(code);
        const keyIndent = m ? m[1].length + (m[2] ? m[2].length : 0) : indent;
        const line = {
            no: i + 1,
            indent: keyIndent,
            key: m ? m[3] : null,
            value: m ? (m[4] || "").trim() : code.trim(),
            comment,
            code,
            raw,
        };
        line.bad = unsupported(line, m);
        if (m && /^[|>][+-]?\d*$/.test(line.value)) block = { indent: keyIndent, key: line.key };
        out.push(line);
    });
    return out;
}

export const unquote = (v) => v.replace(/^(["'])(.*)\1$/, "$2");

/**
 * Structure: top-level keys, the section below a top-level key, and the jobs. A job is a two-space key
 * below jobs, its settings are four-space keys; its status-check name is name when set, else the job id.
 */
export function parseWorkflow(text) {
    const lines = workflowLines(text);
    const plain = lines.filter((l) => !l.scalar);
    const top = (k) => plain.find((l) => l.indent === 0 && l.key === k);
    const section = (k) => {
        const start = plain.indexOf(top(k));
        if (start < 0) return [];
        const end = plain.findIndex((l, i) => i > start && l.indent === 0);
        return plain.slice(start + 1, end < 0 ? plain.length : end);
    };
    const body = section("jobs");
    const heads = body.filter((l) => l.indent === 2 && l.key);
    const jobs = heads.map((head, k) => {
        const own = body.slice(body.indexOf(head) + 1, k + 1 < heads.length ? body.indexOf(heads[k + 1]) : body.length);
        const get = (key) => own.find((l) => l.indent === 4 && l.key === key);
        return { id: head.key, no: head.no, name: get("name") ? unquote(get("name").value) : head.key, own, get };
    });
    return { lines, plain, top, section, jobs };
}

/** A job-level mapping (`with:`, `secrets:`, `permissions:`): { head, entries, inline }; entries are the six-space key lines. */
export function jobMap(job, key) {
    const at = job.own.findIndex((l) => l.indent === 4 && l.key === key);
    if (at < 0) return null;
    const head = job.own[at];
    const rest = job.own.slice(at + 1);
    const end = rest.findIndex((l) => l.indent <= 4);
    return {
        head,
        entries: rest.slice(0, end < 0 ? rest.length : end).filter((l) => l.indent === 6 && l.key),
        inline: unquote(head.value),
    };
}

/** The full text of a value; for a block scalar its body lines, trimmed. */
export function valueText(lines, line) {
    if (!/^[|>][+-]?\d*$/.test(line.value)) return line.value;
    const at = lines.indexOf(line);
    const body = [];
    for (let i = at + 1; i < lines.length && lines[i].scalar === line.key; i++) body.push(lines[i].raw.trim());
    return body.join("\n");
}

/** The body of a block scalar with the common indentation removed and exactly one trailing newline. */
export function blockScalar(lines, keyLine) {
    const start = lines.indexOf(keyLine);
    const body = [];
    for (let i = start + 1; i < lines.length && lines[i].scalar === keyLine.key; i++) body.push(lines[i].raw);
    const indent = Math.min(...body.filter((l) => l.trim()).map((l) => l.match(/^ */)[0].length));
    const text = body.map((l) => l.slice(Math.min(indent, l.match(/^ */)[0].length))).join("\n");
    return `${text.trimEnd()}\n`;
}
