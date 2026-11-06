#include "shim.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include <libxml2/libxml/HTMLparser.h>
#include <libxml2/libxml/HTMLtree.h>
#include <libxml2/libxml/parser.h>
#include <libxml2/libxml/tree.h>

static pthread_once_t libxml_once = PTHREAD_ONCE_INIT;

static void init_libxml_once(void) {
    xmlInitParser();
}

static xmlNodePtr find_body(xmlNodePtr node) {
    for (xmlNodePtr cur = node; cur; cur = cur->next) {
        if (cur->type == XML_ELEMENT_NODE && xmlStrEqual(cur->name, BAD_CAST "body")) {
            return cur;
        }
        xmlNodePtr found = find_body(cur->children);
        if (found) {
            return found;
        }
    }
    return NULL;
}

char *mdx2dict_html_body_xml(const char *html, size_t len) {
    if (!html || len == 0 || len > 0x7fffffff) {
        return NULL;
    }

    pthread_once(&libxml_once, init_libxml_once);

    htmlDocPtr doc = htmlReadMemory(
        html,
        (int)len,
        NULL,
        "UTF-8",
        HTML_PARSE_RECOVER | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING | HTML_PARSE_NONET
    );
    if (!doc) {
        return NULL;
    }

    xmlBufferPtr buffer = xmlBufferCreate();
    if (!buffer) {
        xmlFreeDoc(doc);
        return NULL;
    }

    xmlNodePtr body = find_body(xmlDocGetRootElement(doc));
    if (body) {
        for (xmlNodePtr child = body->children; child; child = child->next) {
            xmlNodeDump(buffer, doc, child, 0, 0);
        }
    } else {
        xmlNodePtr root = xmlDocGetRootElement(doc);
        if (root) {
            xmlNodeDump(buffer, doc, root, 0, 0);
        }
    }

    char *result = NULL;
    const xmlChar *content = xmlBufferContent(buffer);
    if (content) {
        size_t length = xmlBufferLength(buffer);
        result = (char *)malloc(length + 1);
        if (result) {
            memcpy(result, content, length);
            result[length] = '\0';
        }
    }

    xmlBufferFree(buffer);
    xmlFreeDoc(doc);
    return result;
}

void mdx2dict_free(void *ptr) {
    free(ptr);
}
