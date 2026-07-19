#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "sherpa-onnx/c-api/c-api.h"

typedef struct {
  const char *filename;
  const char *text;
} ListeningSample;

static const SherpaOnnxGeneratedAudio *generate(
    const SherpaOnnxOfflineTts *tts, const char *text) {
  SherpaOnnxGenerationConfig generation;
  memset(&generation, 0, sizeof(generation));
  generation.sid = 3;  // zf_001
  generation.speed = 1.0f;
  generation.silence_scale = 0.2f;
  return SherpaOnnxOfflineTtsGenerateWithConfig(
      tts, text, &generation, NULL, NULL);
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: kokoro-listening-samples MODEL_DIRECTORY OUTPUT_DIRECTORY\n");
    return 64;
  }
  if (mkdir(argv[2], 0755) != 0) {
    struct stat info;
    if (stat(argv[2], &info) != 0 || !S_ISDIR(info.st_mode)) return 65;
  }

  char model[4096], voices[4096], tokens[4096], data_dir[4096], lexicon[8192];
  snprintf(model, sizeof(model), "%s/model.int8.onnx", argv[1]);
  snprintf(voices, sizeof(voices), "%s/voices.bin", argv[1]);
  snprintf(tokens, sizeof(tokens), "%s/tokens.txt", argv[1]);
  snprintf(data_dir, sizeof(data_dir), "%s/espeak-ng-data", argv[1]);
  snprintf(
      lexicon, sizeof(lexicon), "%s/lexicon-us-en.txt,%s/lexicon-zh.txt",
      argv[1], argv[1]);

  SherpaOnnxOfflineTtsConfig config;
  memset(&config, 0, sizeof(config));
  config.model.kokoro.model = model;
  config.model.kokoro.voices = voices;
  config.model.kokoro.tokens = tokens;
  config.model.kokoro.data_dir = data_dir;
  config.model.kokoro.lexicon = lexicon;
  config.model.kokoro.length_scale = 1.0f;
  config.model.provider = "cpu";
  config.model.num_threads = 2;
  config.max_num_sentences = 1;

  const SherpaOnnxOfflineTts *tts = SherpaOnnxCreateOfflineTts(&config);
  if (!tts || SherpaOnnxOfflineTtsSampleRate(tts) != 24000 ||
      SherpaOnnxOfflineTtsNumSpeakers(tts) != 103) {
    if (tts) SherpaOnnxDestroyOfflineTts(tts);
    return 2;
  }

  const ListeningSample samples[] = {
      {"01-numbers-money.wav",
       "项目增长3.5%，价格是123.50元，编号是12345。"},
      {"02-date-time.wav",
       "今天是2026年7月19日，会议安排在上午9:30。"},
      {"03-proper-names.wav",
       "李光耀讨论中国、美国和东南亚，也提到了 sherpa onnx、Kokoro 和 AudiobookMaker。"},
      {"04-mixed-language.wav",
       "AI 正在改变 audiobook production，EPUB 会在本机转换为 M4B，全程保持 offline。"},
      {"05-chapter-boundary.wav",
       "第一章到这里结束。第二章，新的世界格局。接下来我们继续讨论中国与世界。"},
  };

  for (size_t index = 0; index < sizeof(samples) / sizeof(samples[0]); ++index) {
    const SherpaOnnxGeneratedAudio *audio = generate(tts, samples[index].text);
    if (!audio || !audio->samples || audio->n <= 0 || audio->sample_rate != 24000) {
      if (audio) SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
      SherpaOnnxDestroyOfflineTts(tts);
      return 3;
    }
    char output[4096];
    snprintf(output, sizeof(output), "%s/%s", argv[2], samples[index].filename);
    if (!SherpaOnnxWriteWave(audio->samples, audio->n, audio->sample_rate, output)) {
      SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
      SherpaOnnxDestroyOfflineTts(tts);
      return 4;
    }
    printf("%s\tframes=%d\tduration=%.3f\n", samples[index].filename,
           audio->n, (double)audio->n / (double)audio->sample_rate);
    SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
  }

  SherpaOnnxDestroyOfflineTts(tts);
  return 0;
}
