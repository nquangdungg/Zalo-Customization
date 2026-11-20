# Thư mục chứa file IPA Zalo Decrypted

Đặt file IPA Zalo đã decrypt (được dump từ TrollStore, CrackerXI, bfdecrypt, DumpDecrypter hoặc tải từ các nguồn IPA decrypt) vào thư mục này.

Ví dụ:
`Decrypted/Zalo_26.11.01.ipa`

## Cách hoạt động của GitHub Actions Workflow:
1. Khi có file `.ipa` trong thư mục `Decrypted/` (hoặc cung cấp link qua Workflow Dispatch `decrypted_ipa_url`), GitHub Actions sẽ:
   - Tự động biên dịch `libZLMod.dylib`.
   - Inject `libZLMod.dylib` và `LC_RPATH` (`@executable_path/Frameworks`) vào file IPA của bạn.
   - Xuất ra 2 bản:
     + **Full**: Giữ nguyên toàn bộ App Extensions (dành cho TrollStore hoặc Developer cert).
     + **No-Appex**: Gỡ bỏ các App Extensions phụ, chỉ dùng 1 App ID duy nhất (khuyến nghị cho tài khoản Apple ID miễn phí qua Sideloadly / SideStore / AltStore).
   - Tự động gắn kèm các file IPA đã inject vào GitHub Release và GitHub Actions Artifacts để tải về cài đặt.
