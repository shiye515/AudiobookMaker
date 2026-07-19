# Third-party notices

AudiobookMaker distributes the native inference runtime, but does not distribute Kokoro model weights in the application bundle.

| Component | Pinned version | License | Distribution |
| --- | --- | --- | --- |
| sherpa-onnx | 1.13.2 (`13d0ae6c539d2809d32f5eaa3ef1db0c459d0b24`) | Apache-2.0 | Universal dynamic XCFramework in the app |
| ONNX Runtime | 1.24.4 | MIT | Universal dynamic XCFramework in the app |
| Kokoro 82M v1.1 zh | `kokoro-int8-multi-lang-v1_1` | Apache-2.0 (license is included in the downloaded package) | Downloaded only after explicit user action |
| eSpeak NG data | Version contained by the Kokoro package | GPL-3.0-or-later; consult the package notices before redistribution | Downloaded as part of the external model package |

The model detail screen links to this notice and to the license file installed with the selected model. The release process must review the exact transitive license set whenever the pinned runtime or model manifest changes.
