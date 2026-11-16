#!/usr/bin/env python3
"""gen_symproto.py - 从内核 BTF 生成运行时符号指针的准确类型

背景
====
lz4hc / 842 / zstdn 这三个模块要绕过「函数本体在 kallsyms 里，但没有
EXPORT_SYMBOL」的符号：kallsyms 查地址存进函数指针，运行期间接调用。
指针必须有准确类型，否则调用点的代码生成和真实 ABI 不符 —— 在
CONFIG_CFI_CLANG 的内核上还会被 kCFI 直接拒绝执行。

zstdn 用 typeof(&f) 从内核头文件取类型，这是最省事也最不会错的做法，
因为类型就是内核自己声明的。842 和 lz4hc 当初是手写签名的：手写会错，
而且换 KMI 之后不会有人再去核对一遍。

这个脚本把这件事变成机械操作：给符号名，从 vmlinux BTF 里取准确原型，
生成一批 typedef。BTF 是内核自己带的那份，与实际运行的二进制必然一致。

用法
====
    # 从设备的 BTF 生成 / 更新头文件
    adb pull /sys/kernel/btf/vmlinux
    python3 scripts/gen_symproto.py --btf vmlinux \\
        --symbols crypto_register_scomp crypto_unregister_scomp \\
                  LZ4_compress_HC LZ4_decompress_safe \\
        --out extra/compat/zram_symproto.h

    # 从编译好的 .ko 反推它到底需要哪些符号（不看 nm，直接读 ELF）
    python3 scripts/gen_symproto.py --btf vmlinux \\
        --from-ko out/lz4hc-android14-6.1.ko --check

    # 设备上核对已提交的头文件是否还和本机内核一致
    python3 scripts/gen_symproto.py --btf /sys/kernel/btf/vmlinux \\
        --verify extra/compat/zram_symproto.h

退出码 0 = 符号全部在 BTF 里；1 = 有缺失，或 --verify 与本机不一致。
"""
import argparse
import struct
import sys

# ---------------------------------------------------------------------------
# BTF 常量
# ---------------------------------------------------------------------------
BTF_KIND_INT = 1
BTF_KIND_PTR = 2
BTF_KIND_ARRAY = 3
BTF_KIND_STRUCT = 4
BTF_KIND_UNION = 5
BTF_KIND_ENUM = 6
BTF_KIND_FWD = 7
BTF_KIND_TYPEDEF = 8
BTF_KIND_VOLATILE = 9
BTF_KIND_CONST = 10
BTF_KIND_RESTRICT = 11
BTF_KIND_FUNC = 12
BTF_KIND_FUNC_PROTO = 13
BTF_KIND_VAR = 14
BTF_KIND_DATASEC = 15
BTF_KIND_FLOAT = 16
BTF_KIND_DECL_TAG = 17
BTF_KIND_TYPE_TAG = 18
BTF_KIND_ENUM64 = 19

# 只有聚合类型需要前置声明；typedef 需要调用方自己提供定义
AGG_KINDS = {
    BTF_KIND_STRUCT: "struct",
    BTF_KIND_UNION: "union",
    BTF_KIND_ENUM: "enum",
    BTF_KIND_FWD: "struct",
}
MASK_KINDS = (BTF_KIND_CONST, BTF_KIND_VOLATILE, BTF_KIND_RESTRICT)


class BTF:
    """最小 BTF 解析器：够取函数原型和渲染 C 类型就行。"""

    def __init__(self, path):
        data = open(path, "rb").read()
        magic, ver, flags, hdr_len, type_off, type_len, str_off, str_len = \
            struct.unpack_from("<HBBIIIII", data, 0)
        if magic != 0xEB9F:
            raise SystemExit(f"{path}: bad BTF magic {magic:#x}")

        base = hdr_len
        ts = base + type_off
        ss = base + str_off

        def get_str(off):
            if off == 0:
                return ""
            a = ss + off
            b = data.index(b"\0", a)
            return data[a:b].decode("utf-8", "replace")

        self.types = [None]
        pos = ts
        end = ts + type_len
        while pos < end:
            name_off, info, sot = struct.unpack_from("<III", data, pos)
            kind = (info >> 24) & 0x1F
            vlen = info & 0xFFFF
            name = get_str(name_off)
            pos += 12

            extra = 0
            if kind == BTF_KIND_INT:
                extra = 4
            elif kind == BTF_KIND_ARRAY:
                extra = 12
            elif kind in (BTF_KIND_STRUCT, BTF_KIND_UNION):
                extra = 12 * vlen
            elif kind == BTF_KIND_ENUM:
                extra = 8 * vlen
            elif kind == BTF_KIND_ENUM64:
                extra = 12 * vlen
            elif kind == BTF_KIND_FUNC_PROTO:
                extra = 8 * vlen
            elif kind == BTF_KIND_VAR:
                extra = 4
            elif kind == BTF_KIND_DATASEC:
                extra = 12 * vlen
            elif kind == BTF_KIND_DECL_TAG:
                extra = 4

            params = []
            if kind == BTF_KIND_FUNC_PROTO:
                for i in range(vlen):
                    pno, pt = struct.unpack_from("<II", data, pos + i * 8)
                    params.append((get_str(pno), pt))

            arr = None
            if kind == BTF_KIND_ARRAY:
                arr = struct.unpack_from("<III", data, pos)

            self.types.append({
                "kind": kind, "name": name, "type": sot,
                "vlen": vlen, "params": params, "arr": arr,
            })
            pos += extra

        self.funcs = {}
        for tid, t in enumerate(self.types):
            if t and t["kind"] == BTF_KIND_FUNC:
                self.funcs[t["name"]] = tid

    # -- 类型打印 ----------------------------------------------------------
    def tname(self, tid, decl=""):
        """把 type id 渲染成 C 声明片段，decl 是嵌进去的变量名。"""
        if tid == 0 or tid >= len(self.types) or self.types[tid] is None:
            return f"void {decl}".strip()

        t = self.types[tid]
        k = t["kind"]

        if k == BTF_KIND_INT:
            return f"{t['name'] or 'int'} {decl}".strip()
        if k == BTF_KIND_FLOAT:
            return f"{t['name'] or 'double'} {decl}".strip()
        if k == BTF_KIND_PTR:
            return self.tname(t["type"], f"*{decl}" if decl else "*")
        if k == BTF_KIND_CONST:
            return "const " + self.tname(t["type"], decl)
        if k == BTF_KIND_VOLATILE:
            return "volatile " + self.tname(t["type"], decl)
        if k == BTF_KIND_RESTRICT:
            return self.tname(t["type"], decl)
        if k == BTF_KIND_TYPE_TAG:
            # __user / __iomem 这类注解，不改 ABI 也不改 C 声明
            return self.tname(t["type"], decl)
        if k == BTF_KIND_TYPEDEF:
            return f"{t['name']} {decl}".strip()
        if k in (BTF_KIND_STRUCT, BTF_KIND_UNION, BTF_KIND_FWD):
            tag = "struct" if k != BTF_KIND_UNION else "union"
            return f"{tag} {t['name']} {decl}".strip()
        if k == BTF_KIND_ENUM:
            return f"enum {t['name']} {decl}".strip()
        if k == BTF_KIND_ARRAY:
            et, idx, nelem = t["arr"]
            return self.tname(et, f"{decl}[{nelem}]" if decl else "[]")
        if k == BTF_KIND_FUNC_PROTO:
            ret = self.tname(t["type"], "")
            args = [self.tname(pt, pn or "") for pn, pt in t["params"]]
            argstr = ", ".join(a for a in args if a) or "void"
            return f"{ret} (*{decl})({argstr})" if decl \
                else f"{ret} (*)({argstr})"
        if k == BTF_KIND_FUNC:
            return self.tname(t["type"], decl)

        return f"void /*kind {k}*/ {decl}".strip()

    def referenced_aggs(self, tid, acc=None):
        """函数签名里引用到的聚合类型，用来决定前置声明哪些。"""
        if acc is None:
            acc = set()
        if tid == 0 or tid >= len(self.types) or self.types[tid] is None:
            return acc
        t = self.types[tid]
        k = t["kind"]
        if k in AGG_KINDS:
            if t["name"]:
                acc.add((k, t["name"]))
            return acc
        if k == BTF_KIND_PTR or k in MASK_KINDS or \
           k in (BTF_KIND_TYPEDEF, BTF_KIND_TYPE_TAG):
            return self.referenced_aggs(t["type"], acc)
        if k == BTF_KIND_ARRAY:
            return self.referenced_aggs(t["arr"][0], acc)
        if k == BTF_KIND_FUNC_PROTO:
            self.referenced_aggs(t["type"], acc)
            for _, pt in t["params"]:
                self.referenced_aggs(pt, acc)
            return acc
        if k == BTF_KIND_FUNC:
            return self.referenced_aggs(t["type"], acc)
        return acc

    def typedefs_used_by_value(self, tid, acc=None):
        """按值参与签名的 typedef：调用方必须自己包含提供定义的头。"""
        if acc is None:
            acc = set()
        if tid == 0 or tid >= len(self.types) or self.types[tid] is None:
            return acc
        t = self.types[tid]
        k = t["kind"]
        if k == BTF_KIND_TYPEDEF:
            acc.add(t["name"])
            return acc
        if k in MASK_KINDS or k == BTF_KIND_TYPE_TAG:
            return self.typedefs_used_by_value(t["type"], acc)
        # 指针后面就不用管了：前置声明足够
        return acc

    def func_signature(self, name):
        """返回 (ret_type_id, [(pname, ptype), ...])，找不到返回 None。"""
        tid = self.funcs.get(name)
        if not tid:
            return None
        proto = self.types[self.types[tid]["type"]]
        if not proto or proto["kind"] != BTF_KIND_FUNC_PROTO:
            return None
        return proto["type"], proto["params"]


def elf_undefined_symbols(path):
    """直接读 ELF64 的符号表，取 SHN_UNDEF 的符号名。

    不依赖 nm —— Windows 上的 Git Bash 没有 binutils，而这台机器就是这样。
    """
    data = open(path, "rb").read()
    if data[:4] != b"\x7fELF":
        raise SystemExit(f"{path}: not an ELF file")
    if data[4] != 2:
        raise SystemExit(f"{path}: only ELF64 is supported")

    e_shoff, = struct.unpack_from("<Q", data, 0x28)
    e_shentsize, e_shnum = struct.unpack_from("<HH", data, 0x3A)

    secs = []
    for i in range(e_shnum):
        secs.append(struct.unpack_from(
            "<IIQQQQIIQQ", data, e_shoff + i * e_shentsize))

    names = set()
    for sh in secs:
        sh_type, sh_off, sh_size, sh_link, sh_entsize = \
            sh[1], sh[4], sh[5], sh[6], sh[9]
        if sh_type not in (2, 11) or not sh_entsize:   # SYMTAB / DYNSYM
            continue
        str_base = secs[sh_link][4]
        for j in range(sh_size // sh_entsize):
            st_name, _info, _other, st_shndx, _val, _sz = struct.unpack_from(
                "<IBBHQQ", data, sh_off + j * sh_entsize)
            if st_shndx != 0 or st_name == 0:
                continue
            a = str_base + st_name
            b = data.index(b"\0", a)
            nm = data[a:b].decode("utf-8", "replace")
            if nm:
                names.add(nm)
    return sorted(names)


def gen(btf, symbols, source_note, regen_cmd):
    lines = []
    W = lines.append

    W("/* SPDX-License-Identifier: GPL-2.0-only */")
    W("/*")
    for l in source_note.split("\n"):
        W(" * " + l if l else " *")
    W(" *")
    W(" * 重新生成：")
    for l in regen_cmd.split("\n"):
        W(" *   " + l)
    W(" */")
    W("#ifndef _ZRAM_SYMPROTO_H")
    W("#define _ZRAM_SYMPROTO_H")
    W("")
    W("#include <linux/types.h>")
    W("")

    sigs = {}
    missing = []
    aggs = set()
    byval = set()
    for s in symbols:
        sig = btf.func_signature(s)
        if not sig:
            missing.append(s)
            continue
        sigs[s] = sig
        ret, params = sig
        btf.referenced_aggs(ret, aggs)
        byval |= btf.typedefs_used_by_value(ret)
        for _, pt in params:
            btf.referenced_aggs(pt, aggs)
            byval |= btf.typedefs_used_by_value(pt)

    if aggs:
        W("/* 下面用到的聚合类型只需要前置声明 */")
        for k, n in sorted(aggs, key=lambda x: x[1]):
            W(f"{AGG_KINDS[k]} {n};")
        W("")

    for s in symbols:
        if s not in sigs:
            continue
        ret, params = sigs[s]
        args = ", ".join(btf.tname(pt, pn or "") for pn, pt in params) or "void"
        retdecl = btf.tname(ret, "")
        W(f"/* {s}: {retdecl} (*)({args}) */")
        W(f"typedef {retdecl} (*zr_t_{s})({args});")
        W("")

    if byval:
        W("/*")
        W(" * 注意：下面这些 typedef 按值出现在签名里，本文件**只当前置声明用**。")
        W(" * 包含本头的编译单元必须自己 include 提供其定义的头文件（例如 zstd")
        W(" * 需要 <linux/zstd.h>），否则编译不过。")
        W(" */")
        for n in sorted(byval):
            W(f"/*   {n} */")
        W("")

    W("#endif /* _ZRAM_SYMPROTO_H */")
    return "\n".join(lines) + "\n", sigs, missing


def main():
    ap = argparse.ArgumentParser(
        description="从内核 BTF 生成运行时符号指针的 typedef")
    ap.add_argument("--btf", required=True, help="vmlinux BTF 路径")
    ap.add_argument("--symbols", nargs="*", default=[],
                    help="要生成 typedef 的符号名")
    ap.add_argument("--from-ko", help="从 .ko 的未定义符号取（直接读 ELF）")
    ap.add_argument("--exclude", nargs="*", default=[],
                    help="从 --from-ko 结果里排除的符号")
    ap.add_argument("--out", help="输出头文件路径；省略则打印到 stdout")
    ap.add_argument("--check", action="store_true",
                    help="只报告哪些符号在 BTF 里有，不生成")
    ap.add_argument("--verify", metavar="HEADER",
                    help="重新生成后与已有头文件逐字节比较")
    ap.add_argument("--source-note", default=None,
                    help="写进头文件的来源说明（默认自动生成）")
    args = ap.parse_args()

    # --verify 的比较对象就是重跑时的输出目标，否则注释里的重跑命令会缺 --out
    if args.verify and not args.out:
        args.out = args.verify

    btf = BTF(args.btf)
    print(f"  BTF: {len(btf.types) - 1} 个 type, {len(btf.funcs)} 个函数",
          file=sys.stderr)

    symbols = list(args.symbols)
    if args.from_ko:
        got = elf_undefined_symbols(args.from_ko)
        if args.exclude:
            ex = set(args.exclude)
            got = [s for s in got if s not in ex]
        symbols += got
        print(f"  {args.from_ko}: {len(got)} 个未定义符号", file=sys.stderr)

    symbols = list(dict.fromkeys(symbols))
    if not symbols:
        raise SystemExit("没有符号可处理")

    note = args.source_note
    if note is None:
        note = ("zram 运行时符号指针的准确类型。\n"
                "\n"
                "GENERATED by scripts/gen_symproto.py from the kernel's own BTF\n"
                "—— 不要手改。要增删符号，重跑脚本。\n"
                "\n"
                "为什么要 BTF 而不是手写：这些符号没有 EXPORT_SYMBOL，类型只能\n"
                "从内核头文件或 BTF 拿。头文件不一定包含（842/lz4hc 刻意见得不\n"
                "依赖它），BTF 一定有，而且就是当前跑到的那颗内核自己的。")

    regen = "python3 scripts/gen_symproto.py --btf <vmlinux.btf> \\\n"
    regen += "    --symbols " + " ".join(symbols) + " \\\n"
    if args.out:
        regen += "    --out " + args.out.replace("\\", "/")

    code, sigs, missing = gen(btf, symbols, note, regen)

    print(f"  可生成: {len(sigs)}   BTF 里没有: {len(missing)}", file=sys.stderr)
    for m in missing:
        print(f"    - {m}（BTF 里没有这个函数）", file=sys.stderr)

    if args.check:
        for s in symbols:
            print(f"    {'OK  ' if s in sigs else 'MISS'} {s}")
        return 0 if not missing else 1

    if args.verify:
        try:
            old = open(args.verify, encoding="utf-8").read()
        except FileNotFoundError:
            print(f"  {args.verify}: 不存在", file=sys.stderr)
            return 1
        if old == code:
            print(f"  {args.verify}: 与本机内核一致", file=sys.stderr)
            return 0
        print(f"  {args.verify}: 与本机内核不一致，需要重新生成", file=sys.stderr)
        import difflib
        for l in list(difflib.unified_diff(
                old.splitlines(), code.splitlines(),
                "committed", "generated", lineterm=""))[:40]:
            print(l, file=sys.stderr)
        return 1

    if args.out:
        with open(args.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(code)
        print(f"  -> {args.out}", file=sys.stderr)
    else:
        print(code, end="")

    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())