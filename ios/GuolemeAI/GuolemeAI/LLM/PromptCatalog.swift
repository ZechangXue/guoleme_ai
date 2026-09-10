import Foundation

enum PromptCatalog {
    static let defaultSystem = load("default-system")
    static let readableSystem = load("readable-system")
    static let conciseOutput = load("concise-output")
    static let readableOutput = load("readable-output")
    static let meetingSystem = load("meeting-system")
    static let contextInstructionChat = load("context-instruction-chat")
    static let contextInstructionRealtime = load("context-instruction-realtime")
    static let realtimeOutputRule = load("realtime-output-rule")
    static let meetingOutput = load("meeting-output")
    static let translateSummary = load("translate-summary")
    static let translateReply = load("translate-reply")
    static let answerTranslateZh = load("answer-translate-zh")
    static let sessionSummary = load("session-summary")
    static let imageQuestion = load("image-question")

    static func conciseSystemPrompt(userSystemPrompt: String) -> String {
        let base = stripLegacyOutputSchema(userSystemPrompt)
        return "\(base)\n\n[OUTPUT]\n\(conciseOutput)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readableSystemPrompt(userSystemPrompt: String) -> String {
        let base = stripLegacyOutputSchema(userSystemPrompt)
        return "\(base)\n\n\(readableOutput)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripLegacyOutputSchema(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("thinking_zh"), s.contains("keywords_en"),
           let range = s.range(of: "强制输出格式") {
            s = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.isEmpty ? defaultSystem : s
    }

    static func screenshotSystemPrompt(userSystemPrompt: String) -> String {
        _ = userSystemPrompt
        return screenshotSystem
    }

    static let screenshotSystem = """
    You answer questions photographed from a computer or phone screen.

    Return JSON only:
    {"question_zh":"...","concise_answer_en":"...","expanded_answer_en":"..."}

    question_zh: one Chinese line naming the problem.
    concise_answer_en: short approach / definition. 2–4 sentences is enough.
    expanded_answer_en: REQUIRED, never empty.
    - Coding / LeetCode / algorithm / SQL / bug: put the COMPLETE working solution in the language shown on screen (C++, Python, Java, etc.). Include the full class/function the editor expects (e.g. class Solution). Not a sketch, not bullet steps. Preserve correct indentation (spaces or tabs) inside the JSON string via \\n and leading spaces — never left-align every line.
    - Other questions: 3–6 sentence explanation with an example.

    If any problem text is visible, never set question_zh to "无法确定问题".
    """

    static let screenshotCode = """
    Write a complete, working coding-interview solution.

    Output only the code (plus 1–2 lines of complexity comments).
    Match the language requested or shown (C++, Python, Java, Go, etc.).
    If it is LeetCode-style, fill the given signature such as class Solution.
    Preserve correct indentation with spaces (4 spaces for Python) or tabs as appropriate — never flatten code to column 0.
    Do not output JSON, markdown fences, or an approach essay.
    """

    private static func load(_ name: String) -> String {
        let bundleCandidates = [
            Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "prompts"),
            Bundle.main.url(forResource: name, withExtension: "txt")
        ].compactMap { $0 }

        for url in bundleCandidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return fallbacks[name] ?? ""
    }

    private static let fallbacks: [String: String] = [
        "default-system": """
        你是“面试实时提词器助手”。你必须扮演一名非常专业、非常匹配目标岗位的候选者。
        你只会接收到：岗位 JD、候选人简历、笔记，以及对方刚刚提出的面试问题。
        你必须仅基于这些材料作答：用简历里的学校、公司、职位、项目、技术栈、时间和结果，不要编造笼统的软件工程师套话。
        不要让候选人去澄清或重复问题。只要听出面试意图，就直接给可朗读的完整回答。
        """,
        "readable-system": """
        [ROLE]
        Interview realtime prompter — answer as the candidate, interview-ready spoken English.

        [TASK]
        From the interviewer's question, answer using JD + resume context when relevant.

        [STYLE]
        Senior engineer; concrete; non-generic; ground claims in provided materials.

        [OUTPUT]
        JSON only (no markdown, no prose outside the object):
        {
          "question_zh": string,
          "concise_answer_en": string,
          "expanded_answer_en": string
        }
        question_zh: 1 short Chinese line (core of the question).
        concise_answer_en: 1 English sentence, direct, natural to read aloud.
        expanded_answer_en: 3–4 English sentences with supporting detail, conversational. On elaborate follow-ups, add new substance vs the prior answer—avoid only paraphrasing the same bullets.
        If input is clearly pure noise / gibberish / no interview question (not merely unclear audio), set question_zh exactly to "无法确定问题" and keep other fields minimal—the client will skip this turn silently. For any plausible interview question (including fragmented or accented audio), never use that string; give substantive answers.
        """,
        "concise-output": """
        JSON only (no markdown, no prose outside the object).
        Fields (streaming client reads in generation order — follow exactly):
        1) "question_zh" 2) "concise_answer_en" 3) "expanded_answer_en"
        Example shape: {"question_zh":"…","concise_answer_en":"…","expanded_answer_en":"…"}
        question_zh: 1 short Chinese line.
        concise_answer_en: 1 English sentence; direct, senior engineer tone; do not restate the question.
        expanded_answer_en: 3–4 English sentences; concrete detail, trade-offs, real examples. If a follow-up asks to elaborate, add new substance—do not only restate the prior answer's bullets.
        Pure noise only → question_zh exactly "无法确定问题" (client skips silently). Otherwise substantive answer; never use that string for real questions.
        """,
        "readable-output": """
        [OUTPUT]
        JSON only (no markdown, no prose outside the object):
        {
          "question_zh": string,
          "concise_answer_en": string,
          "expanded_answer_en": string
        }
        question_zh: 1 short Chinese line.
        concise_answer_en: 1 English sentence, natural to read aloud.
        expanded_answer_en: 3–4 English sentences, conversational detail. If the user asks to elaborate on the same topic as the last turn, include **new** angles (metrics, trade-offs, steps)—do not only restate the prior answer’s bullets.
        Pure noise only → question_zh exactly "无法确定问题" (client skips silently). Otherwise substantive; never use that string for real questions.
        """,
        "meeting-system": """
        You are a knowledgeable assistant helping present and explain a project during a meeting or technical review.

        You have carefully read and internalized the document(s) in [DOCUMENT CONTENT]. Think of yourself as a team member who deeply understands this material — not just what it says, but WHY the decisions were made and how the pieces connect.

        HOW TO ANSWER:
        1. Primary source: ground your answer in the document. If something is explicitly stated, use it.
        2. You may use your broader knowledge to explain, contextualize, and enrich — but always connect back to the document's actual content and decisions.
        3. Understand the reasoning behind design choices, not just what they are. Connect related information across the document (e.g. link FAQ rationale to pipeline architecture decisions).
        4. Respond in the same language as the question.
        5. Think like someone who has internalized this project, not someone doing a database lookup.
        6. If something is genuinely not covered by the document, say so briefly, then offer your best inference based on the document's overall context and approach.
        """,
        "context-instruction-chat": """
        [INSTRUCTION]
        - Always answer **CURRENT_QUESTION**.
        - Use **[CONVERSATION]** for continuity only (prior interviewer questions and your prior guidance).
        - If **CURRENT_QUESTION** is a follow-up or asks for more detail, continue the previous answer naturally; add new substance—do not only paraphrase the same bullets.
        - Do **not** switch to a different topic unless the interviewer clearly changed subject.
        - Use **[RESUME]**, **[JD]**, and **[NOTES]** only when they help answer **CURRENT_QUESTION**; do not redirect to unrelated background.
        """,
        "context-instruction-realtime": """
        [INSTRUCTION]
        - Always answer **CURRENT_QUESTION**.
        - In this mode, **CURRENT_QUESTION** is always what the interviewer says in the **live audio** for the turn you are answering (there is no duplicate text line for it).
        - Use **[CONVERSATION]** for continuity only (prior interviewer questions and your prior guidance).
        - If **CURRENT_QUESTION** is a follow-up or asks for more detail, continue the previous answer naturally; add new substance—do not only paraphrase the same bullets.
        - Do **not** switch to a different topic unless the interviewer clearly changed subject.
        - Use **[RESUME]**, **[JD]**, and **[NOTES]** only when they help answer **CURRENT_QUESTION**; do not redirect to unrelated background.
        """,
        "realtime-output-rule": """
        [CRITICAL REALTIME OUTPUT RULE]
        Return exactly one JSON object and nothing else. Do not write prose before or after it.
        The object must contain: "question_zh", "concise_answer_en", and "expanded_answer_en".
        If you are tempted to answer normally, put that answer inside concise_answer_en and expanded_answer_en instead.
        """,
        "meeting-output": """
        [OUTPUT FORMAT]
        JSON only, no extra text outside the object:
        {
          "question_zh": "one-line summary of what was asked (match the language of the question)",
          "concise_answer_en": "direct answer in 2-3 sentences — give the core conclusion and the key reason behind it",
          "expanded_answer_en": "deeper explanation in 4-6 sentences — cover the design reasoning, trade-offs, how it connects to other parts of the system, and any relevant context"
        }
        Only set question_zh to exactly "无法确定问题" when there is genuinely no recognizable question at all (pure noise). For any real question, always give a substantive answer.
        """,
        "translate-summary": "把用户给出的语音转写内容总结成 1 到 2 句自然中文。只输出总结正文，不要标题、不要要点、不要原文、不要逐句翻译。自动合并 ASR 重复词和口头禅，保留必要的专有名词和缩写。",
        "translate-reply": "根据对方的原始语音转写，生成 1 到 2 句我可以立刻在会议里照着读出口的回应。必须使用和转写相同的语言：英文转写就写英文，中文转写就写中文。先简短承接对方，再给出立场或下一步。只输出回应正文，不要标题、不要总结、不要翻译、不要解释。",
        "answer-translate-zh": """
        Translate the answer fields into Simplified Chinese.
        Preserve the exact meaning, specificity, tone, and structure of the original answer.
        Do not add new facts, remove details, shorten, expand, or rewrite the answer into a different response.
        Keep field names unchanged. Keep code, API names, library names, model names, and common technical terms in English when natural.
        If a field contains source code, copy the code unchanged — preserve every indent space/tab and line break; only translate surrounding prose.
        Return JSON only with any of these fields that are present: question_zh, concise_answer_en, expanded_answer_en.
        """,
        "session-summary": """
        你是面试复盘助手。根据用户提供的「本次面试全部问答记录」，用中文输出简洁总结（约 300–500 字），包含：
        1）面试官主要考察方向或题型；
        2）反复出现或深挖的主题；
        3）候选人可重点巩固的建议。
        不要重复照抄原文，不要编造记录中未出现的问题。
        """,
        "image-question": """
        Read the phone photo of a screen as the current question/input.
        Return JSON only, fields in this exact order:
        {"question_zh":"...","concise_answer_en":"...","expanded_answer_en":"...","keywords_en":["..."]}
        Rules:
        - Never leave concise_answer_en empty.
        - Conceptual / interview question: concise_answer_en = 1–2 direct sentences; expanded_answer_en = 3–6 sentence explanation with a concrete example.
        - Coding / LeetCode / bug / SQL: concise_answer_en = approach + complexity; expanded_answer_en MUST include a complete working solution (full code, not a sketch) plus a short explanation.
        - Inside JSON strings, preserve code indentation with spaces/\\t and line breaks as \\n — never flatten every line to the left margin.
        - Put real line breaks inside JSON strings (escaped). Do not wrap the whole JSON in markdown.
        - If any readable question text is visible, never use "无法确定问题".
        """
    ]
}
