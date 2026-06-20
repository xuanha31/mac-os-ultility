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
#include <freerdp/gdi/gdi.h>
#include <freerdp/graphics.h>
#include <freerdp/input.h>
#include <freerdp/update.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/channels/channels.h>

/* PIXEL_FORMAT_BGRA32 là macro hàm → không import sang Swift được.
 * Bọc thành hàm inline để Swift lấy giá trị hằng. */
static inline UINT32 cfreerdp_pixel_format_bgra32(void) {
    return PIXEL_FORMAT_BGRA32;
}

#endif /* CFREERDP_SHIM_H */
