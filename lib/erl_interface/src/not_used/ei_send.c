/*
 * %CopyrightBegin%
 * 
 * Copyright Ericsson AB 2001-2009. All Rights Reserved.
 * 
 * The contents of this file are subject to the Erlang Public License,
 * Version 1.1, (the "License"); you may not use this file except in
 * compliance with the License. You should have received a copy of the
 * Erlang Public License along with this software. If not, it can be
 * retrieved online at http://www.erlang.org/.
 * 
 * Software distributed under the License is distributed on an "AS IS"
 * basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
 * the License for the specific language governing rights and limitations
 * under the License.
 * 
 * %CopyrightEnd%
 *

 */
#ifdef __WIN32__
#include <winsock2.h>
#include <windows.h>
#include <winbase.h>

#elif VXWORKS
#include <sys/types.h>
#include <unistd.h>

#else /* unix */
#include <sys/types.h>
#include <unistd.h>
#include <sys/uio.h>
#endif

#include "eidef.h"
#include "eiext.h"
#include "ei_connect.h"
#include "ei_internal.h"
#include "putget.h"
#include "ei_trace.h"
#include "show_msg.h"

/* FIXME this is not useed !!!!! */

/* length (4), PASS_THROUGH (1), header, message */
int ei_ei_send_encoded(ei_cnode* ec, int fd, const erlang_pid *to,
		       const char *msg, int msglen)
{
  char *s, header[1200]; /* see size calculation below */
  erlang_trace *token = NULL;
  int index = 5; /* reserve 5 bytes for control message */
#ifdef HAVE_WRITEV
  struct iovec v[2];
#endif

  /* are we tracing? */
  /* check that he can receive trace tokens first */
  if (ei_distversion(fd) > 0)
    token = ei_trace(0,(erlang_trace *)NULL);
    
  /* header = SEND, cookie, to                      max sizes: */
  ei_encode_version(header,&index);                     /*   1 */
  if (token) {
    ei_encode_tuple_header(header,&index,4);            /*   2 */
    ei_encode_long(header,&index,ERL_SEND_TT);          /*   2 */
  } else {
    ei_encode_tuple_header(header,&index,3);
    ei_encode_long(header,&index,ERL_SEND); 
  }
  ei_encode_atom(header,&index, "" /*ei_getfdcookie(ec, fd)*/);       /* 258 */
  ei_encode_pid(header,&index,to);                      /* 268 */
    
  if (token) ei_encode_trace(header,&index,token);      /* 534 */
    
  /* control message (precedes header actually) */
  /* length = 1 ('p') + header len + message len */
  s = header;
  put32be(s, index + msglen - 4);                       /*   4 */
  put8(s, ERL_PASS_THROUGH);                                /*   1 */
  /*** sum: 1070 */
    
#ifdef DEBUG_DIST
  if (ei_trace_distribution > 0) ei_show_sendmsg(stderr,header,msg);
#endif
    
#ifdef HAVE_WRITEV
    
  v[0].iov_base = (char *)header;
  v[0].iov_len = index;
  v[1].iov_base = (char *)msg;
  v[1].iov_len = msglen;
    
  if (writev(fd,v,2) != index+msglen) return -1;
    
#else  /* !HAVE_WRITEV */
    
  if (writesocket(fd,header,index) != index) return -1;
  if (writesocket(fd,msg,msglen) != msglen) return -1;
    
#endif  /* !HAVE_WRITEV */
    
  return 0;
}
