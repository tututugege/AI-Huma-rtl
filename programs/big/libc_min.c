typedef unsigned int size_t;
void *memcpy(void *d, const void *s, size_t n){ char *a=d; const char *b=s; while(n--) *a++=*b++; return d; }
void *memset(void *d, int c, size_t n){ char *a=d; while(n--) *a++=(char)c; return d; }
char *strcpy(char *d, const char *s){ char *r=d; while((*d++=*s++)); return r; }
int strcmp(const char *a, const char *b){ while(*a && *a==*b){a++;b++;} return (unsigned char)*a-(unsigned char)*b; }
size_t strlen(const char *s){ size_t n=0; while(s[n]) n++; return n; }
