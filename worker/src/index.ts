/**
 * Kivo Click Proxy Worker (Groq Vision Edition)
 *
 * Proxies Anthropic client requests to Groq (Llama 3.2 Vision)
 * and translates the stream response back to Anthropic format.
 * This keeps Kivo Click completely free, fast, and private.
 *
 * Routes:
 *   POST /chat  → Groq chat completions (Llama 3.2 Vision)
 */

interface Env {
  GROQ_API_KEY: string;
  GROQ_AUDIO_KEY?: string;
  GEMINI_API_KEY?: string;
  GEMINI_TTS_API_KEY?: string;
  AZURE_SPEECH_KEY?: string;
  AZURE_SPEECH_REGION?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Enable CORS for testing
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, Authorization",
        },
      });
    }

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        const response = await handleChat(request, env);
        // Add CORS headers to response
        const corsResponse = new Response(response.body, response);
        corsResponse.headers.set("Access-Control-Allow-Origin", "*");
        return corsResponse;
      }
      
      if (url.pathname === "/tts") {
        const response = await handleTTS(request, env);
        // Add CORS headers to response
        const corsResponse = new Response(response.body, response);
        corsResponse.headers.set("Access-Control-Allow-Origin", "*");
        return corsResponse;
      }

      if (url.pathname === "/transcribe") {
        const response = await handleTranscribe(request, env);
        const corsResponse = new Response(response.body, response);
        corsResponse.headers.set("Access-Control-Allow-Origin", "*");
        return corsResponse;
      }
      
      // Native speech and local transcription mean these are unused
      if (url.pathname === "/transcribe-token") {
        return new Response(JSON.stringify({ error: "Endpoint deprecated in favor of native offline APIs" }), {
          status: 410,
          headers: { "Content-Type": "application/json" }
        });
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json", "Access-Control-Allow-Origin": "*" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env): Promise<Response> {
  const anthropicRequest = await request.json() as any;
  const requestedModel = anthropicRequest.model || "";
  const isGemini = requestedModel.startsWith("gemini-");
  const isLlama33 = requestedModel === "llama-3.3-70b-versatile";

  console.log(`[handleChat] Incoming request for model: "${requestedModel}"`);

  if (isGemini) {
    if (!env.GEMINI_API_KEY) {
      console.log(`[handleChat] Error: GEMINI_API_KEY not configured in env`);
      return new Response(
        JSON.stringify({ error: "GEMINI_API_KEY environment variable is not configured on the worker. Please configure it in your Cloudflare Worker dashboard or .dev.vars." }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      );
    }
  } else {
    if (!env.GROQ_API_KEY) {
      console.log(`[handleChat] Error: GROQ_API_KEY not configured in env`);
      return new Response(
        JSON.stringify({ error: "GROQ_API_KEY environment variable is not configured on the worker." }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      );
    }
  }

  // Build OpenAI format messages
  const openaiMessages: any[] = [];

  // Add system prompt if present
  if (anthropicRequest.system) {
    openaiMessages.push({
      role: "system",
      content: anthropicRequest.system,
    });
  }

  let hasImage = false;

  // Map messages from Anthropic format to OpenAI format
  if (anthropicRequest.messages && Array.isArray(anthropicRequest.messages)) {
    for (const msg of anthropicRequest.messages) {
      const role = msg.role;
      const content = msg.content;

      if (Array.isArray(content)) {
        const mappedContent = content.map((block: any) => {
          if (block.type === "text") {
            return {
              type: "text",
              text: block.text,
            };
          } else if (block.type === "image") {
            hasImage = true;
            return {
              type: "image_url",
              image_url: {
                url: `data:${block.source.media_type};base64,${block.source.data}`,
              },
            };
          }
          return block;
        });
        openaiMessages.push({ role, content: mappedContent });
      } else {
        openaiMessages.push({ role, content });
      }
    }
  }

  // If Llama 3.3 and we have images, run Stage 1: Vision analysis using Llama 4 Scout
  let screenAnalysis = "";
  if (isLlama33 && hasImage) {
    console.log(`[handleChat] Hybrid Model: Running Stage 1 Vision analysis using Llama 4 Scout`);
    try {
      const visionResponse = await fetch("https://api.groq.com/openai/v1/chat/completions", {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${env.GROQ_API_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "meta-llama/llama-4-scout-17b-16e-instruct",
          messages: [
            {
              role: "system",
              content: "You are a precise screen analyzer. Look at the user's screen capture. Identify and locate important elements (like application icons, buttons, spotlight, dock, menus, or windows) relevant to the user request. Output a structured summary of the screen state and list the grid coordinates (using [GRID:RowCol:element_name] where row is A-L and column is 1-12, e.g. [GRID:K11:App Store] in dock or [GRID:A12:Spotlight] magnifier). Do not answer the user's query, just provide the annotation and list of coordinates."
            },
            ...openaiMessages.filter((m: any) => m.role === "user")
          ],
          max_tokens: 400
        })
      });

      if (visionResponse.ok) {
        const visionData = await visionResponse.json() as any;
        screenAnalysis = visionData.choices?.[0]?.message?.content || "";
        console.log(`[handleChat] Stage 1 Vision Output:\n${screenAnalysis}`);
      } else {
        const errText = await visionResponse.text();
        console.error(`[handleChat] Stage 1 Vision Failed: status=${visionResponse.status}, body=${errText}`);
      }
    } catch (e) {
      console.error("[handleChat] Error running Stage 1 Vision:", e);
    }
  }

  const upstreamURL = isGemini
    ? "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
    : "https://api.groq.com/openai/v1/chat/completions";

  const upstreamAuth = isGemini
    ? `Bearer ${env.GEMINI_API_KEY}`
    : `Bearer ${env.GROQ_API_KEY}`;

  let upstreamModel = "meta-llama/llama-4-scout-17b-16e-instruct";
  let finalMessages = openaiMessages;

  if (isGemini) {
    upstreamModel = requestedModel;
  } else if (isLlama33) {
    upstreamModel = "llama-3.3-70b-versatile";
    
    // Construct final messages for reasoning
    let finalSystemPrompt = anthropicRequest.system || "";
    if (hasImage && screenAnalysis) {
      finalSystemPrompt = `${finalSystemPrompt}\n\n[SCREEN ANALYSIS CONTEXT]\nThe following elements and coordinates were detected on the user's screen:\n${screenAnalysis}\nUse this information and coordinates (using [GRID:RowCol:label] or [POINT:x%,y%:label]) in your response to point things out on their screen.`;
    }

    finalMessages = [];
    finalMessages.push({ role: "system", content: finalSystemPrompt });

    for (const msg of openaiMessages) {
      if (msg.role === "system") continue;
      if (Array.isArray(msg.content)) {
        let filtered = msg.content.filter((block: any) => block.type !== "image_url");
        if (filtered.length === 0) {
          filtered = [{ type: "text", text: "[Screen Image Analyzed]" }];
        }
        finalMessages.push({ role: msg.role, content: filtered });
      } else {
        finalMessages.push(msg);
      }
    }
  }

  const upstreamResponse = await fetch(upstreamURL, {
    method: "POST",
    headers: {
      "Authorization": upstreamAuth,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: upstreamModel,
      messages: finalMessages,
      max_tokens: anthropicRequest.max_tokens || 1024,
      stream: true,
    }),
  });

  if (!upstreamResponse.ok) {
    const errorText = await upstreamResponse.text();
    console.error(`[handleChat] Upstream error (${isGemini ? "Gemini" : "Groq"}): status=${upstreamResponse.status}, body=${errorText}`);
    return new Response(errorText, { status: upstreamResponse.status });
  }

  // Process stream and transform OpenAI chunk to Anthropic chunk
  const { readable, writable } = new TransformStream();
  const writer = writable.getWriter();
  const reader = upstreamResponse.body!.getReader();
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  (async () => {
    let buffer = "";
    let fullText = "";
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop() || "";

        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed) continue;
          
          if (trimmed === "data: [DONE]") {
            await writer.write(encoder.encode("data: [DONE]\n\n"));
            break;
          }

          if (trimmed.startsWith("data: ")) {
            try {
              const dataJson = JSON.parse(trimmed.slice(6));
              const textChunk = dataJson.choices?.[0]?.delta?.content || "";
              if (textChunk) {
                fullText += textChunk;
                // Return in the Anthropic content_block_delta format expected by the Swift client
                const anthropicChunk = {
                  type: "content_block_delta",
                  index: 0,
                  delta: {
                    type: "text_delta",
                    text: textChunk,
                  },
                };
                await writer.write(encoder.encode(`data: ${JSON.stringify(anthropicChunk)}\n\n`));
              }
            } catch (err) {
              // Ignore JSON parse errors on incomplete stream lines
            }
          }
        }
      }
      console.log(`[handleChat] Full streaming response: "${fullText}"`);
      await writer.write(encoder.encode("data: [DONE]\n\n"));
    } catch (err) {
      console.error("Streaming error:", err);
    } finally {
      await writer.close();
    }
  })();

  return new Response(readable, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
    },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const reqBody = await request.json() as any;
  const text = reqBody.text || "";
  const voice = reqBody.voice || "Aoede";

  if (!text) {
    return new Response(JSON.stringify({ error: "Missing 'text' in request body" }), {
      status: 400,
      headers: { "Content-Type": "application/json" }
    });
  }

  const voiceLower = voice.toLowerCase();
  const isOrpheus = voiceLower === "leo" || voiceLower === "tara" || voiceLower === "daniel" || voiceLower === "hannah" || voiceLower.startsWith("orpheus");

  if (isOrpheus) {
    console.log(`[handleTTS] Routing TTS request to Orpheus Audio API (voice: ${voice})`);
    return await handleOrpheusTTS(text, voice, env);
  } else {
    console.log(`[handleTTS] Routing TTS request to Google Audio API (voice: ${voice})`);
    return await handleGoogleTTS(text, voice, env);
  }
}

async function handleOrpheusTTS(text: string, voice: string, env: Env): Promise<Response> {
  const groqAudioKey = env.GROQ_AUDIO_KEY || env.GROQ_API_KEY;
  if (!groqAudioKey) {
    return new Response(JSON.stringify({ error: "GROQ_AUDIO_KEY and GROQ_API_KEY environment variables are not configured on the worker." }), {
      status: 500,
      headers: { "Content-Type": "application/json" }
    });
  }

  const voiceLower = voice.toLowerCase();
  const voiceName = (voiceLower === "tara" || voiceLower === "hannah") ? "hannah" : "daniel";

  console.log(`[handleOrpheusTTS] Calling Groq Orpheus API for voice "${voiceName}" (mapped from "${voice}")`);
  try {
    const response = await fetch("https://api.groq.com/openai/v1/audio/speech", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${groqAudioKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        model: "canopylabs/orpheus-v1-english",
        input: text,
        voice: voiceName,
        response_format: "wav"
      })
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error(`[handleOrpheusTTS] Groq Orpheus API error: status=${response.status}, body=${errorText}`);
      return new Response(errorText, { status: response.status });
    }

    const wavArrayBuffer = await response.arrayBuffer();
    const wavBytes = new Uint8Array(wavArrayBuffer);
    const pcmBytes = extractPCMFromWav(wavBytes);

    console.log(`[handleOrpheusTTS] Successfully generated audio. Strip WAV header: ${wavBytes.length} -> ${pcmBytes.length} bytes`);
    return new Response(pcmBytes, {
      headers: {
        "Content-Type": "audio/pcm"
      }
    });
  } catch (err) {
    console.error("[handleOrpheusTTS] Failed to fetch from Groq Orpheus TTS:", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" }
    });
  }
}

function extractPCMFromWav(wavBytes: Uint8Array): Uint8Array {
  const len = wavBytes.length;
  // Limit the search of 'data' subchunk to the first 100 bytes to avoid false matches in the audio data
  for (let i = 12; i < Math.min(100, len - 8); i++) {
    if (
      wavBytes[i] === 100 &&
      wavBytes[i + 1] === 97 &&
      wavBytes[i + 2] === 116 &&
      wavBytes[i + 3] === 97
    ) {
      let dataSize = wavBytes[i + 4] | (wavBytes[i + 5] << 8) | (wavBytes[i + 6] << 16) | (wavBytes[i + 7] << 24);
      const startOffset = i + 8;
      
      // If dataSize is 0xffffffff (-1), it means the data runs until the end of the file
      if (dataSize === -1 || dataSize < 0) {
        dataSize = len - startOffset;
      }
      
      const endOffset = Math.min(startOffset + dataSize, len);
      return wavBytes.subarray(startOffset, endOffset);
    }
  }
  if (wavBytes[0] === 82 && wavBytes[1] === 73 && wavBytes[2] === 70 && wavBytes[3] === 70) {
    return wavBytes.subarray(44);
  }
  return wavBytes;
}

async function handleTranscribe(request: Request, env: Env): Promise<Response> {
  if (!env.GROQ_API_KEY) {
    return new Response(JSON.stringify({ error: "GROQ_API_KEY environment variable is not configured on the worker." }), {
      status: 500,
      headers: { "Content-Type": "application/json" }
    });
  }

  try {
    const formData = await request.formData();
    const file = formData.get("file");
    const model = formData.get("model") || "whisper-large-v3-turbo";

    if (!file) {
      return new Response(JSON.stringify({ error: "Missing 'file' in multipart form data." }), {
        status: 400,
        headers: { "Content-Type": "application/json" }
      });
    }

    const groqFormData = new FormData();
    groqFormData.append("file", file);
    groqFormData.append("model", model);
    groqFormData.append("response_format", "json");

    console.log(`[handleTranscribe] Routing Speech-to-Text request to Groq Whisper (${model})`);

    const groqResponse = await fetch("https://api.groq.com/openai/v1/audio/transcriptions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${env.GROQ_API_KEY}`
      },
      body: groqFormData
    });

    if (!groqResponse.ok) {
      const errorText = await groqResponse.text();
      console.error(`[handleTranscribe] Groq Whisper API error: status=${groqResponse.status}, body=${errorText}`);
      return new Response(errorText, { status: groqResponse.status });
    }

    const resJson = await groqResponse.json() as any;
    return new Response(JSON.stringify(resJson), {
      status: 200,
      headers: {
        "Content-Type": "application/json"
      }
    });
  } catch (err) {
    console.error("[handleTranscribe] Exception occurred:", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" }
    });
  }
}

async function handleGoogleTTS(text: string, voice: string, env: Env): Promise<Response> {
  let geminiResponse: Response | null = null;
  const ttsKey = env.GEMINI_TTS_API_KEY || env.GEMINI_API_KEY;
  if (ttsKey) {
    const geminiURL = `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent?key=${ttsKey}`;
    const body = {
      contents: [
        {
          parts: [
            {
              text: text
            }
          ]
        }
      ],
      generation_config: {
        response_modalities: ["AUDIO"],
        speech_config: {
          voice_config: {
            prebuilt_voice_config: {
              voice_name: voice
            }
          }
        }
      }
    };

    try {
      geminiResponse = await fetch(geminiURL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      });
    } catch (e) {
      console.error("[handleGoogleTTS] Gemini fetch error:", e);
    }
  }

  if (geminiResponse && geminiResponse.ok) {
    try {
      const json = await geminiResponse.json() as any;
      const base64Data = json.candidates?.[0]?.content?.parts?.[0]?.inlineData?.data;
      if (base64Data) {
        const binaryString = atob(base64Data);
        const len = binaryString.length;
        const bytes = new Uint8Array(len);
        for (let i = 0; i < len; i++) {
          bytes[i] = binaryString.charCodeAt(i);
        }
        return new Response(bytes, {
          headers: {
            "Content-Type": "audio/pcm",
          }
        });
      }
    } catch (err) {
      console.error("[handleGoogleTTS] Error parsing Gemini response:", err);
    }
  }

  console.log("[handleGoogleTTS] Gemini TTS failed or rate-limited. Attempting Azure TTS fallback...");
  const azureResponse = await handleAzureTTS(text, voice, env);
  if (azureResponse) {
    return azureResponse;
  }

  const fallbackStatus = geminiResponse ? geminiResponse.status : 500;
  const fallbackText = geminiResponse ? await geminiResponse.text() : "TTS generation failed on both primary (Gemini) and backup (Azure) systems";
  return new Response(fallbackText, { status: fallbackStatus });
}

async function handleAzureTTS(text: string, voice: string, env: Env): Promise<Response | null> {
  if (!env.AZURE_SPEECH_KEY) {
    console.log("[handleAzureTTS] Azure Speech Key not configured.");
    return null;
  }

  const region = env.AZURE_SPEECH_REGION || "eastus";
  const url = `https://${region}.tts.speech.microsoft.com/cognitiveservices/v1`;
  const azureVoice = voice === "Puck" ? "en-US-AndrewNeural" : "en-US-JennyNeural";
  const escapedText = text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');

  const ssml = `<speak version='1.0' xml:lang='en-US'><voice xml:lang='en-US' name='${azureVoice}'>${escapedText}</voice></speak>`;

  console.log(`[handleAzureTTS] Calling Azure Speech API (${region}) for voice ${azureVoice}`);
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        "Ocp-Apim-Subscription-Key": env.AZURE_SPEECH_KEY,
        "Content-Type": "application/ssml+xml",
        "X-Microsoft-OutputFormat": "raw-24khz-16bit-mono-pcm",
        "User-Agent": "KivoClick/1.0"
      },
      body: ssml
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error(`[handleAzureTTS] Azure API error: status=${response.status}, body=${errorText}`);
      return null;
    }

    const arrayBuffer = await response.arrayBuffer();
    return new Response(new Uint8Array(arrayBuffer), {
      headers: {
        "Content-Type": "audio/pcm",
      }
    });
  } catch (e) {
    console.error("[handleAzureTTS] Failed to fetch from Azure TTS:", e);
    return null;
  }
}
