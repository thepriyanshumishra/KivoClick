const fs = require('fs');
const path = require('path');
const https = require('https');

const voices = {
  aoede: {
    provider: 'google',
    voiceName: 'Aoede',
    displayName: 'Aoede (Google Female)'
  },
  puck: {
    provider: 'google',
    voiceName: 'Puck',
    displayName: 'Puck (Google Male)'
  },
  hannah: {
    provider: 'orpheus',
    voiceName: 'hannah',
    displayName: 'Hannah (Orpheus Female)'
  },
  daniel: {
    provider: 'orpheus',
    voiceName: 'daniel',
    displayName: 'Daniel (Orpheus Male)'
  }
};

const errors = {
  limit_exceeded: "Gemini rate limit reached. Attempting to connect to backup voice services.",
  network_error: "Network connection issue. Please check your internet connection.",
  general_error: "An error occurred. Please try again in a moment."
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function getGeminiApiKey() {
  const varsPath = path.join(__dirname, '..', 'worker', '.dev.vars');
  if (fs.existsSync(varsPath)) {
    const content = fs.readFileSync(varsPath, 'utf8');
    const ttsKeyMatch = content.match(/GEMINI_TTS_API_KEY\s*=\s*["']?([^"'\r\n]+)["']?/);
    if (ttsKeyMatch && ttsKeyMatch[1]) {
      return ttsKeyMatch[1];
    }
    const apiKeyMatch = content.match(/GEMINI_API_KEY\s*=\s*["']?([^"'\r\n]+)["']?/);
    if (apiKeyMatch && apiKeyMatch[1]) {
      return apiKeyMatch[1];
    }
  }
  return null;
}

function getGroqApiKey() {
  const varsPath = path.join(__dirname, '..', 'worker', '.dev.vars');
  if (fs.existsSync(varsPath)) {
    const content = fs.readFileSync(varsPath, 'utf8');
    const audioKeyMatch = content.match(/GROQ_AUDIO_KEY\s*=\s*["']?([^"'\r\n]+)["']?/);
    if (audioKeyMatch && audioKeyMatch[1]) {
      return audioKeyMatch[1];
    }
    const apiKeyMatch = content.match(/GROQ_API_KEY\s*=\s*["']?([^"'\r\n]+)["']?/);
    if (apiKeyMatch && apiKeyMatch[1]) {
      return apiKeyMatch[1];
    }
  }
  return null;
}

function fetchGeminiTTS(text, voice, apiKey) {
  return new Promise((resolve, reject) => {
    const url = `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent?key=${apiKey}`;
    const payload = JSON.stringify({
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
    });

    const parsedUrl = new URL(url);
    const options = {
      hostname: parsedUrl.hostname,
      path: parsedUrl.pathname + parsedUrl.search,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload)
      }
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => {
        data += chunk;
      });

      res.on('end', () => {
        if (res.statusCode !== 200) {
          reject(new Error(`API responded with status ${res.statusCode}: ${data}`));
          return;
        }

        try {
          const json = JSON.parse(data);
          const base64Data = json.candidates?.[0]?.content?.parts?.[0]?.inlineData?.data;
          if (!base64Data) {
            reject(new Error("No audio data found in API response"));
            return;
          }
          resolve(Buffer.from(base64Data, 'base64'));
        } catch (e) {
          reject(e);
        }
      });
    });

    req.on('error', (err) => {
      reject(err);
    });

    req.write(payload);
    req.end();
  });
}

function fetchOrpheusTTS(text, voice, apiKey) {
  return new Promise((resolve, reject) => {
    const url = 'https://api.groq.com/openai/v1/audio/speech';
    const payload = JSON.stringify({
      model: "canopylabs/orpheus-v1-english",
      input: text,
      voice: voice,
      response_format: "wav"
    });

    const parsedUrl = new URL(url);
    const options = {
      hostname: parsedUrl.hostname,
      path: parsedUrl.pathname,
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload)
      }
    };

    const req = https.request(options, (res) => {
      const chunks = [];
      res.on('data', (chunk) => {
        chunks.push(chunk);
      });

      res.on('end', () => {
        if (res.statusCode !== 200) {
          const bodyStr = Buffer.concat(chunks).toString();
          reject(new Error(`Orpheus API responded with status ${res.statusCode}: ${bodyStr}`));
          return;
        }

        resolve(Buffer.concat(chunks));
      });
    });

    req.on('error', (err) => {
      reject(err);
    });

    req.write(payload);
    req.end();
  });
}

function buildWavHeader(dataLength, sampleRate = 24000) {
  const header = Buffer.alloc(44);
  
  // RIFF identifier
  header.write('RIFF', 0);
  // file length minus RIFF header length (8 bytes)
  header.writeUInt32LE(36 + dataLength, 4);
  // RIFF type
  header.write('WAVE', 8);
  
  // format chunk identifier
  header.write('fmt ', 12);
  // format chunk length
  header.writeUInt32LE(16, 16);
  // sample format (raw PCM)
  header.writeUInt16LE(1, 20);
  // channel count (1 for mono)
  header.writeUInt16LE(1, 22);
  // sample rate
  header.writeUInt32LE(sampleRate, 24);
  // byte rate = sampleRate * channels * bytesPerSample
  header.writeUInt32LE(sampleRate * 1 * 2, 28);
  // block align = channels * bytesPerSample
  header.writeUInt16LE(2, 32);
  // bits per sample
  header.writeUInt16LE(16, 34);
  
  // data chunk identifier
  header.write('data', 36);
  // data chunk length
  header.writeUInt32LE(dataLength, 40);
  
  return header;
}

async function run() {
  const geminiApiKey = getGeminiApiKey();
  const groqApiKey = getGroqApiKey();
  
  if (!geminiApiKey) {
    console.error("❌ Error: Could not find GEMINI_API_KEY or GEMINI_TTS_API_KEY in worker/.dev.vars");
    process.exit(1);
  }
  if (!groqApiKey) {
    console.error("❌ Error: Could not find GROQ_API_KEY or GROQ_AUDIO_KEY in worker/.dev.vars");
    process.exit(1);
  }

  const outputDir = path.join(__dirname, '..', 'leanring-buddy');
  
  console.log("🔊 Starting Premium Voice Offline Asset Generation (Google & Orpheus)...");
  console.log(`Output Directory: ${outputDir}`);

  for (const [voiceKey, voiceConfig] of Object.entries(voices)) {
    console.log(`\nProcessing Voice: ${voiceConfig.displayName}`);
    
    for (const [errorKey, text] of Object.entries(errors)) {
           const fileName = `${errorKey}_${voiceKey}.wav`;
      const filePath = path.join(outputDir, fileName);
      
      if (fs.existsSync(filePath)) {
        console.log(`   Skipping ${fileName} (already exists)`);
        continue;
      }
      
      console.log(`\nGenerating ${fileName}...`);
      let success = false;
      for (let attempt = 1; attempt <= 3; attempt++) {
        try {
          if (voiceConfig.provider === 'google') {
            const rawPcm = await fetchGeminiTTS(text, voiceConfig.voiceName, geminiApiKey);
            const wavHeader = buildWavHeader(rawPcm.length);
            const wavData = Buffer.concat([wavHeader, rawPcm]);
            fs.writeFileSync(filePath, wavData);
          } else {
            // Orpheus already returns a fully-formatted WAV file
            const wavData = await fetchOrpheusTTS(text, voiceConfig.voiceName, groqApiKey);
            fs.writeFileSync(filePath, wavData);
          }
          console.log(`   Successfully wrote: ${fileName}`);
          success = true;
          break;
        } catch (err) {
          console.error(`   Attempt ${attempt} failed: ${err.message}`);
          if (attempt < 3) {
            console.log(`   Waiting 15 seconds before retry...`);
            await sleep(15000);
          }
        }
      }

      if (!success) {
        console.error(`❌ Failed to generate ${fileName}`);
        process.exit(1);
      }

      // 10-second delay to avoid rate limits
      console.log("Waiting 10 seconds before next request...");
      await sleep(10000);
    }
  }
  
  console.log("\n✅ Offline Voice Asset Generation Complete!");
}

run();
