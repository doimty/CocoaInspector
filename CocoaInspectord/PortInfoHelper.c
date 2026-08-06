#include <mach/mach.h>
#include <mach/ipc_info.h>

kern_return_t mach_port_object_type(
    task_t task,
    mach_port_name_t name,
    uint32_t *object_type,
    mach_vm_address_t *object_addr
) {
    // ipc_info_object_type_t is natural_t which is uint32_t on arm64.
    // The C function takes ipc_info_object_type_t * but we want to call it
    // from Swift without depending on the SDK's Swift availability gate.
    return mach_port_kobject(task, name, (ipc_info_object_type_t *)object_type, object_addr);
}