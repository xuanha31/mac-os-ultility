/* Shim phơi bày FreeRDP 3.x cho Swift.
 * Header tìm qua -I<prefix>/include/freerdp3 và -I<prefix>/include/winpr3
 * (cSettings trong Package.swift). Chỉ biên dịch khi đã cài FreeRDP (Homebrew),
 * Package.swift dò freerdp.h trước khi thêm target CFreeRDP. */
#ifndef CFREERDP_SHIM_H
#define CFREERDP_SHIM_H

#include <winpr/synch.h>
#include <winpr/error.h>

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/event.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/graphics.h>
#include <freerdp/input.h>
#include <freerdp/update.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/channels/disp.h>
#include <freerdp/client/disp.h>

/* PIXEL_FORMAT_BGRA32 là macro hàm → không import sang Swift được.
 * Bọc thành hàm inline để Swift lấy giá trị hằng. */
static inline UINT32 cfreerdp_pixel_format_bgra32(void) {
    return PIXEL_FORMAT_BGRA32;
}

/* RDP_CLIENT_INTERFACE_VERSION là #define và sizeof(rdpContext) là toán tử C →
 * Swift không lấy trực tiếp được. Bọc inline để dựng RDP_CLIENT_ENTRY_POINTS. */
static inline UINT32 cfreerdp_client_interface_version(void) {
    return RDP_CLIENT_INTERFACE_VERSION;
}

static inline UINT32 cfreerdp_context_size(void) {
    return (UINT32)sizeof(rdpContext);
}

/* PubSub_Subscribe* là macro/inline + handler kênh của client common → gói lại để Swift
 * gọi 1 hàm. Đăng ký để khi kênh GFX/RAIL… nối, FreeRDP tự gdi_graphics_pipeline_init
 * (đổ GFX vào gdi.primary_buffer). Không có bước này thì GFX vẽ surface riêng → màn trắng. */
static inline void cfreerdp_subscribe_channel_handlers(rdpContext* ctx) {
    if (!ctx || !ctx->pubSub) return;
    PubSub_SubscribeChannelConnected(ctx->pubSub, freerdp_client_OnChannelConnectedEventHandler);
    PubSub_SubscribeChannelDisconnected(ctx->pubSub, freerdp_client_OnChannelDisconnectedEventHandler);
}

/* Đăng ký THÊM handler riêng của app cho sự kiện "channel connected" — dùng để bắt
 * con trỏ CliprdrClientContext khi kênh "cliprdr" nối (FreeRDP chỉ cấp kênh, phần cầu
 * nối clipboard ↔ NSPasteboard do app tự lo). PubSub_Subscribe* là macro nên bọc lại. */
static inline void cfreerdp_subscribe_channel_connected(rdpContext* ctx,
                                                        pChannelConnectedEventHandler fn) {
    if (!ctx || !ctx->pubSub) return;
    PubSub_SubscribeChannelConnected(ctx->pubSub, fn);
}

#endif /* CFREERDP_SHIM_H */
