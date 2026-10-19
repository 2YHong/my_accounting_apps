# 中文离线语音识别模型

模型：sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23。

原模型由 marcoyang 提供，使用 WenetSpeech 训练；本软件采用 csukuangfj 发布的 ONNX 模型，搭配 k2-fsa 的 sherpa-onnx 运行库。模型为 Apache License 2.0，完整许可见同目录 LICENSE。

模型来源：https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23

模型文档：https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/zipformer-transducer-models.html#csukuangfj-sherpa-onnx-streaming-zipformer-zh-14m-2023-02-23-chinese

下载来源：https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23.tar.bz2

按照官方 int8 示例，使用量化 encoder、原精度 decoder、量化 joiner 和 tokens.txt，合计 30,975,688 字节。文件未修改。

| 文件 | SHA-256 |
| --- | --- |
| encoder-epoch-99-avg-1.int8.onnx | 1c556ea57cec304e55ec4b72e52c1cc098bb01476ed7d90f3de939fe126487b1 |
| decoder-epoch-99-avg-1.onnx | 5ee0f03a2768ff1d5c83ef3a493243c7935d316cd41280037b14783a3467cc78 |
| joiner-epoch-99-avg-1.int8.onnx | a7cf9d82757bdcf786059454495a9ca95e4bd7347f72473fc08d794475c36169 |
| tokens.txt | 8b294db9045d6e5f94647f4c1eec1af4da143a75053c399611444b378ff966ac |
