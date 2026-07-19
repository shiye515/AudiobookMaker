#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sherpa-onnx/c-api/c-api.h"

int main(int argc, char **argv) {
  if (argc < 3 || argc > 4) {
    fprintf(stderr, "usage: kokoro-smoke MODEL_DIRECTORY OUTPUT_WAV [THREADS]\n");
    return 64;
  }
  char model[4096], voices[4096], tokens[4096], data_dir[4096], lexicon[8192];
  snprintf(model, sizeof(model), "%s/model.int8.onnx", argv[1]);
  snprintf(voices, sizeof(voices), "%s/voices.bin", argv[1]);
  snprintf(tokens, sizeof(tokens), "%s/tokens.txt", argv[1]);
  snprintf(data_dir, sizeof(data_dir), "%s/espeak-ng-data", argv[1]);
  snprintf(lexicon, sizeof(lexicon), "%s/lexicon-us-en.txt,%s/lexicon-zh.txt", argv[1], argv[1]);

  SherpaOnnxOfflineTtsConfig config;
  memset(&config, 0, sizeof(config));
  config.model.kokoro.model = model;
  config.model.kokoro.voices = voices;
  config.model.kokoro.tokens = tokens;
  config.model.kokoro.data_dir = data_dir;
  config.model.kokoro.lexicon = lexicon;
  config.model.kokoro.length_scale = 1.0f;
  config.model.provider = "cpu";
  config.model.num_threads = argc == 4 ? atoi(argv[3]) : 2;
  config.max_num_sentences = 1;

  const SherpaOnnxOfflineTts *tts = SherpaOnnxCreateOfflineTts(&config);
  if (!tts) return 2;
  if (SherpaOnnxOfflineTtsSampleRate(tts) != 24000 || SherpaOnnxOfflineTtsNumSpeakers(tts) != 103) return 3;
  SherpaOnnxGenerationConfig generation;
  memset(&generation, 0, sizeof(generation));
  generation.sid = 3;
  generation.speed = 1.0f;
  generation.silence_scale = 0.2f;
  const SherpaOnnxGeneratedAudio *audio = SherpaOnnxOfflineTtsGenerateWithConfig(
      tts, "你好，这是 AudiobookMaker 的 Kokoro 本机语音测试。", &generation, NULL, NULL);
  if (!audio || audio->n <= 0 || audio->sample_rate != 24000) return 4;
  int ok = SherpaOnnxWriteWave(audio->samples, audio->n, audio->sample_rate, argv[2]);
  printf("samples=%d sample_rate=%d speakers=%d threads=%d\n", audio->n, audio->sample_rate,
         SherpaOnnxOfflineTtsNumSpeakers(tts), config.model.num_threads);
  SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
  SherpaOnnxDestroyOfflineTts(tts);
  return ok ? 0 : 5;
}
