#include <mach/mach.h>

// ipc_info_object_type_t is defined in the private mach/ipc_info.h header.
// The header is not in the public SDK path, so we define the type ourselves.
// It is natural_t (uint32_t on arm64) — the same underlying type used by
// mach_port_kobject before the iOS 17 SDK introduced the named typedef.
typedef uint32_t ipc_info_object_type_t;

kern_return_t mach_port_object_type(
    task_t task,
    mach_port_name_t name,
    uint32_t *object_type,
    mach_vm_address_t *object_addr
) {
    return mach_port_kobject(task, name, (ipc_info_object_type_t *)object_type, object_addr);
}