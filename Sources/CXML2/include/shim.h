#ifndef MDX2DICT_SHIM_H
#define MDX2DICT_SHIM_H

#include <stddef.h>

/// 用 libxml2 的 HTML 解析器把 HTML 的 <body> 子节点序列化成 XML。
/// 与 Foundation 的 XMLDocument(.documentTidyHTML) 不同，libxml2 会保留
/// 词典使用的自定义标签，便于原 CSS 继续生效。
/// 返回 malloc 分配的 UTF-8 字符串，调用方用 mdx2dict_free 释放。
char *mdx2dict_html_body_xml(const char *html, size_t len);

void mdx2dict_free(void *ptr);

#endif
