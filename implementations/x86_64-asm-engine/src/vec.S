/*
 * vec.S - vectorized batch kernels (mode "vectorized").
 */
#include "pq.inc"
#include "sql.inc"
#include "exec.inc"

    .section .note.GNU-stack, "", @progbits
    .text

FUNC vk_filter
    jmp rk_filter
ENDF vk_filter
FUNC vk_project
    jmp rk_project
ENDF vk_project
FUNC vk_agg_single
    jmp rk_agg_single
ENDF vk_agg_single
FUNC vk_agg_groups
    jmp rk_agg_groups
ENDF vk_agg_groups
FUNC vk_group_keys
    jmp rk_group_keys
ENDF vk_group_keys
