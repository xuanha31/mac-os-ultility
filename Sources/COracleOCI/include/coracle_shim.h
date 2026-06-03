/* Shim phơi bày Oracle Call Interface (oci.h) cho Swift.
 * oci.h được tìm qua -I/opt/oracle/instantclient/sdk/include (cSettings trong Package.swift).
 * Chỉ biên dịch khi Instant Client SDK đã cài (Package.swift dò oci.h trước khi thêm target). */
#ifndef CORACLE_SHIM_H
#define CORACLE_SHIM_H

#include <oci.h>

#endif /* CORACLE_SHIM_H */
