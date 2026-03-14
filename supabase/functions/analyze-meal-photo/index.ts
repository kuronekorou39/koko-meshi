import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const PROMPT = `この写真を分析して、以下の情報をJSON形式で返してください。

必ず以下のJSON形式のみで回答してください（説明文は不要）:
{
  "menu_name": "メニュー名（日本語）",
  "estimated_price": 数値（円、整数）,
  "estimated_calories": 数値（kcal、整数）,
  "cuisine_genre": "料理ジャンル（例: ラーメン、寿司、カフェ、中華、イタリアン等）"
}

注意:
- menu_nameは具体的な料理名を推定してください（例: 「味噌ラーメン」「カルボナーラ」）
- 複数の料理が写っている場合はメインの料理名を記載してください
- 価格は日本の一般的な相場から推定してください
- カロリーは一般的な1人前の量から推定してください
- 料理が写っていない場合も必ず同じJSON形式で回答してください。写っているものを短く描写してmenu_nameに入れ、priceとcaloriesは0、cuisine_genreは「写真」としてください（例: menu_name「夕焼けの海」）`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // --- 1. JWT認証 ---
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonResponse({ error: "unauthorized" }, 401);
    }

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } },
    );

    const {
      data: { user },
      error: authError,
    } = await supabaseClient.auth.getUser();
    if (authError || !user) {
      return jsonResponse({ error: "unauthorized" }, 401);
    }

    // --- 2. レート制限 ---
    const isAnonymous = user.is_anonymous === true;
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const { data: profile } = await supabaseAdmin
      .from("profiles")
      .select("ai_usage_count, ai_usage_reset_at")
      .eq("id", user.id)
      .single();

    let usageCount = profile?.ai_usage_count ?? 0;
    const maxUsage = isAnonymous ? 3 : 90;

    // ログイン済みユーザーは月次リセット
    if (!isAnonymous && profile) {
      const resetAt = new Date(profile.ai_usage_reset_at);
      const now = new Date();
      if (
        now.getMonth() !== resetAt.getMonth() ||
        now.getFullYear() !== resetAt.getFullYear()
      ) {
        usageCount = 0;
        await supabaseAdmin
          .from("profiles")
          .update({
            ai_usage_count: 0,
            ai_usage_reset_at: now.toISOString(),
          })
          .eq("id", user.id);
      }
    }

    if (usageCount >= maxUsage) {
      return jsonResponse(
        {
          error: isAnonymous
            ? "anonymous_limit_reached"
            : "rate_limit_exceeded",
          limit: maxUsage,
          used: usageCount,
        },
        429,
      );
    }

    // --- 3. リクエスト解析 ---
    const { image_base64, context } = await req.json();
    if (!image_base64) {
      return jsonResponse({ error: "image_base64 is required" }, 400);
    }

    // --- 4. AI呼び出し ---
    const fullPrompt = context ? `${context}\n\n${PROMPT}` : PROMPT;
    const aiProvider = Deno.env.get("AI_PROVIDER") ?? "gemini";
    console.log(`[AI] Provider: ${aiProvider}, image size: ${Math.round(image_base64.length / 1024)}KB`);

    let result;
    let model: string;

    if (aiProvider === "claude") {
      result = await callClaude(image_base64, fullPrompt);
      model = "claude-haiku-4-5";
    } else {
      result = await callGemini(image_base64, fullPrompt);
      model = "gemini-2.5-flash";
    }

    // AIがパース可能な結果を返せなかった場合もデフォルト値で成功扱い
    const DEFAULT_RESULT = {
      menu_name: "不明",
      estimated_price: 0,
      estimated_calories: 0,
      cuisine_genre: "不明",
    };

    if (!result) {
      console.log(`[AI] No parseable result - returning defaults`);
      result = DEFAULT_RESULT;
    }

    // 必須フィールドの欠落を補完
    result = { ...DEFAULT_RESULT, ...result };

    console.log(`[AI] Result: ${result.menu_name} (${result.estimated_price}円, ${result.estimated_calories}kcal)`);

    // --- 5. 使用回数を記録 ---
    await supabaseAdmin
      .from("profiles")
      .update({ ai_usage_count: usageCount + 1 })
      .eq("id", user.id);

    // --- 6. 結果を返す ---
    return jsonResponse({ ...result, model });
  } catch (error) {
    console.error("Edge Function error:", error);
    return jsonResponse({ error: (error as Error).message }, 500);
  }
});

// --- ヘルパー関数 ---

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function callClaude(imageBase64: string, prompt: string) {
  const apiKey = Deno.env.get("CLAUDE_API_KEY");
  if (!apiKey) throw new Error("CLAUDE_API_KEY not configured");

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: "claude-haiku-4-5-20251001",
      max_tokens: 256,
      messages: [
        {
          role: "user",
          content: [
            {
              type: "image",
              source: {
                type: "base64",
                media_type: "image/jpeg",
                data: imageBase64,
              },
            },
            { type: "text", text: prompt },
          ],
        },
      ],
    }),
  });

  if (!response.ok) {
    const errBody = await response.text();
    console.error(`Claude API error: ${response.status} ${errBody}`);
    return null;
  }

  const body = await response.json();
  const text = body.content?.[0]?.text;
  return text ? extractJson(text) : null;
}

async function callGemini(imageBase64: string, prompt: string) {
  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) throw new Error("GEMINI_API_KEY not configured");

  const response = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${apiKey}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [
          {
            parts: [
              {
                inlineData: { mimeType: "image/jpeg", data: imageBase64 },
              },
              { text: prompt },
            ],
          },
        ],
        generationConfig: { maxOutputTokens: 8192 },
      }),
    },
  );

  if (!response.ok) {
    const errBody = await response.text();
    console.error(`Gemini API error: ${response.status} ${errBody}`);
    return null;
  }

  const body = await response.json();
  console.log(`[Gemini] Response keys: ${JSON.stringify(Object.keys(body))}`);
  const candidates = body.candidates;
  if (!candidates?.length) {
    const blockReason = body.promptFeedback?.blockReason;
    console.log(`[Gemini] No candidates. blockReason: ${blockReason}`);
    if (blockReason) {
      return {
        menu_name: "刺激が強すぎる何か",
        estimated_price: 0,
        estimated_calories: 0,
        cuisine_genre: "禁断の味",
      };
    }
    return null;
  }

  const parts = candidates[0].content?.parts;
  if (!parts?.length) {
    console.error(`[Gemini] No parts. Candidate: ${JSON.stringify(candidates[0]).substring(0, 500)}`);
    return null;
  }

  console.log(`[Gemini] Parts count: ${parts.length}, types: ${parts.map((p: Record<string, unknown>) => p.text ? (p.thought ? 'thought' : 'text') : 'other').join(',')}`);

  // Gemini 2.5はthinking partsを含む場合がある
  let text: string | null = null;
  for (const part of parts) {
    if (part.text && !part.thought) {
      text = part.text;
      break;
    }
  }
  // fallback: 最後のtextパートを使用
  if (!text) {
    for (let i = parts.length - 1; i >= 0; i--) {
      if (parts[i].text) {
        text = parts[i].text;
        break;
      }
    }
  }

  if (!text) {
    console.error(`[Gemini] No text found in parts`);
    return null;
  }

  console.log(`[Gemini] Raw text: ${text.substring(0, 300)}`);
  const parsed = extractJson(text);
  if (!parsed) {
    console.error(`[Gemini] Failed to parse JSON from: ${text.substring(0, 500)}`);
  }
  return parsed;
}

function extractJson(text: string) {
  // fenced JSON block
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fenced) {
    try {
      return JSON.parse(fenced[1].trim());
    } catch (e) {
      console.error(`[extractJson] fenced parse error: ${(e as Error).message}`);
    }
  }
  // raw JSON
  const braces = text.match(/\{[\s\S]*\}/);
  if (braces) {
    try {
      return JSON.parse(braces[0]);
    } catch (e) {
      console.error(`[extractJson] braces parse error: ${(e as Error).message}`);
    }
  }
  // 最終手段: 不正なJSONを修復を試みる（末尾カンマ除去等）
  const braces2 = text.match(/\{[\s\S]*\}/);
  if (braces2) {
    try {
      const fixed = braces2[0]
        .replace(/,\s*}/g, "}")  // 末尾カンマ除去
        .replace(/,\s*]/g, "]"); // 配列末尾カンマ除去
      return JSON.parse(fixed);
    } catch { /* skip */ }
  }
  return null;
}
