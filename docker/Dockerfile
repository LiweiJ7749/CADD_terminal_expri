FROM centos:7 AS libg2c

WORKDIR /tmp/rpm
COPY docker/vendor/compat-libf2c-34-3.4.6-19.el6.x86_64.rpm ./
RUN mkdir -p /out \
    && rpm2cpio compat-libf2c-34-3.4.6-19.el6.x86_64.rpm | cpio -idmv \
    && cp -a usr/lib64/libg2c.so.0* /out/

FROM perl:5.38-slim

ENV ZDOCK_HOME=/opt/zdock
ENV LD_LIBRARY_PATH=/usr/local/lib
ENV PATH=/opt/zdock:${PATH}

COPY --from=libg2c /out/libg2c.so.0 /usr/local/lib/libg2c.so.0
COPY --from=libg2c /out/libg2c.so.0.0.0 /usr/local/lib/libg2c.so.0.0.0
COPY zdock3.0.2_linux_x64/ ${ZDOCK_HOME}/
COPY docker/entrypoint.sh /usr/local/bin/zdock-entrypoint

RUN chmod 755 /usr/local/bin/zdock-entrypoint \
    && chmod 755 ${ZDOCK_HOME}/mark_sur ${ZDOCK_HOME}/zdock ${ZDOCK_HOME}/create_lig ${ZDOCK_HOME}/uniCHARMM \
    && chmod 755 ${ZDOCK_HOME}/create.pl ${ZDOCK_HOME}/block.pl \
    && ldconfig

ENTRYPOINT ["/usr/local/bin/zdock-entrypoint"]
CMD ["bash"]