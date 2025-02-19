FROM alpine:edge as R-fs-builder
LABEL maintainer="cgiraldo@gradiant.org"
LABEL organization="gradiant.org"

RUN apk add --no-cache autoconf \
                       automake \
                       libtool \
                       linux-headers
#fs-bug https://github.com/r-lib/fs/pull/158. Creating a local Rpackage from latest github sources
RUN wget -O /fs-master.zip https://github.com/r-lib/fs/archive/master.zip
RUN unzip /fs-master.zip && cd /fs-master/src/libuv/ && ./autogen.sh && cd / && tar -cvzf fs-master.tgz fs-master/


FROM alpine:edge as arrow-builder

LABEL maintainer="cgiraldo@gradiant.org"
LABEL organization="gradiant.org"

## Adding apache arrow build dependencies
RUN apk add --no-cache build-base bash cmake boost-dev py3-numpy py-numpy-dev python3-dev autoconf zlib-dev flex bison
RUN pip3 install cython
## Downloading and building arrow source
RUN wget -qO- https://github.com/apache/arrow/archive/apache-arrow-0.13.0.tar.gz | tar xvz -C /opt
RUN ln -s /opt/arrow-apache-arrow-0.13.0 /opt/arrow 

ENV ARROW_BUILD_TYPE=release \
    ARROW_HOME=/opt/dist \
    PARQUET_HOME=/opt/dist

RUN /bin/bash
RUN mkdir /opt/dist
RUN mkdir -p /opt/arrow/cpp/build 
RUN cd /opt/arrow/cpp/build  && \
    cmake -DCMAKE_BUILD_TYPE=$ARROW_BUILD_TYPE \
      -DCMAKE_INSTALL_PREFIX=$ARROW_HOME \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DARROW_PARQUET=on \
      -DARROW_PYTHON=on \
      -DARROW_PLASMA=on \
      -DARROW_BUILD_TESTS=OFF \
      -DPYTHON_EXECUTABLE=/usr/bin/python3 \
      .. && \
    make -j4 && \
    make install

#build pyarrow
RUN cp -r /opt/dist/* /
RUN cd /opt/arrow/python && \
    python3 setup.py build_ext --build-type=$ARROW_BUILD_TYPE \
       --with-parquet --with-plasma --inplace
RUN cd /opt/arrow/python && \
    python3 setup.py bdist_egg
RUN mkdir -p /opt/dist/python && cp /opt/arrow/python/dist/* /opt/dist/python

# We will extract alpine hadoop native libraries from this stage 
FROM gradiant/hadoop-base:2.7.7 as hadoop

FROM alpine:edge

LABEL maintainer="cgiraldo@gradiant.org" \
      organization="gradiant.org"

ENV JUPYTER_VERSION=5.7.8 \
    JUPYTERLAB_VERSION=0.35.5 \
    JUPYTER_PORT=8888 \
    JUPYTERLAB=false \
    JUPYTERHUB_VERSION=0.9.6 \
    NB_USER=jovyan \
    NB_UID=1000 \
    NB_GID=100 

##############################
# JUPYTER layers
##############################
RUN set -ex && \
    apk add --no-cache bash \
        build-base \
        git \        
        libxml2-dev \
        libxslt-dev \
        python3 \
        python3-dev \
        zeromq-dev \
        && \
    pip3 install --no-cache-dir --upgrade pip && \
    # https://github.com/jupyter/notebook/issues/4311
    #pip3 install --no-cache-dir tornado==5.1.1 && \
    pip3 install --no-cache-dir notebook==${JUPYTER_VERSION} jupyterlab==${JUPYTERLAB_VERSION} nbgitpuller==0.6.1 ipywidgets==7.4.2 jupyter-contrib-nbextensions==0.5.1 && \
    jupyter serverextension enable --py nbgitpuller --sys-prefix && \
    jupyter contrib nbextension install && \ 
    wget https://github.com/jgm/pandoc/releases/download/2.6/pandoc-2.6-linux.tar.gz && \
    tar -xvzf pandoc-2.6-linux.tar.gz && \
    mv pandoc-2.6/bin/pandoc* /usr/local/bin/ && \
    rm -rf pandoc* && \
    # Jupyterhub option
    pip3 install --no-cache-dir jupyterhub==${JUPYTERHUB_VERSION} && \
    apk add --no-cache linux-pam \
                       npm && \
    npm install -g configurable-http-proxy

##############################
# Spark Support layer
##############################

ENV JAVA_HOME=/usr/lib/jvm/default-jvm/ \
    SPARK_VERSION=2.4.2 \
    SPARK_HOME=/opt/spark
ENV PATH="$PATH:$SPARK_HOME/sbin:$SPARK_HOME/bin" \
    SPARK_URL="local[*]" \
    PYTHONPATH="${SPARK_HOME}/python/lib/pyspark.zip:${SPARK_HOME}/python/lib/py4j-src.zip:$PYTHONPATH" \
    SPARK_OPTS="" \
    SPARKCONF_SPARK_KUBERNETES_CONTAINER_IMAGE="gradiant/spark:$SPARK_VERSION-python"

# Copy native libraries from gradiant/hadoop-base docker image
COPY --from=hadoop /opt/hadoop/lib/native/* /lib/
RUN ln -s /lib /lib64 && \
    apk add --no-cache openjdk8-jre libc6-compat nss maven && mkdir -p /opt && \
    wget -qO- https://archive.apache.org/dist/spark/spark-$SPARK_VERSION/spark-$SPARK_VERSION-bin-hadoop2.7.tgz | tar xvz -C /opt && \
    ln -s /opt/spark-$SPARK_VERSION-bin-hadoop2.7 /opt/spark && \
    cd /opt/spark/python/lib && ln -s py4j-*-src.zip py4j-src.zip

# ADDING KAFKA LIBRARIES
RUN wget http://central.maven.org/maven2/org/apache/spark/spark-sql-kafka-0-10_2.12/$SPARK_VERSION/spark-sql-kafka-0-10_2.12-$SPARK_VERSION.jar \
    -O /opt/spark/jars/spark-sql-kafka-0-10_2.12-$SPARK_VERSION.jar && \
    wget http://central.maven.org/maven2/org/apache/kafka/kafka-clients/2.0.0/kafka-clients-2.0.0.jar \
    -O /opt/spark/jars/kafka-clients-2.0.0.jar


##############################
# PYTHON Data-science layers
##############################
# ADDING PYARROW SUPPORT
# install pyarrow for efficient pandas dataframe <-> spark dataframe
COPY  --from=arrow-builder /opt/dist/ /usr/

RUN set -ex && \
    # enabling testing repo
    echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories && \    
    apk add --no-cache \
        py3-matplotlib \      
        py3-numpy \       
        py3-numpy-f2py \
        py3-pandas \
        py3-scikit-learn \
        py3-scipy \
        && \
    #apk add --allow-untrusted /py3-scikit-learn-0.20.3-r0.apk && rm /py3-scikit-learn-0.20.3-r0.apk && \
    python3 -m pip install --no-cache-dir --upgrade pip setuptools  && \
    pip3 install --no-cache-dir pandasql plotly ipyleaflet && \
    # findspark to use pyspark with regular ipython kernel. At the beggining of your notebook run
    # import findspark
    # findspark.init()
    # import pyspark
    pip3 install findspark && \
    # install pyarrow for efficient pandas dataframe <-> spark dataframe
    apk add --no-cache boost-regex boost-filesystem boost-system && \
    easy_install /usr/python/pyarrow-0.13.0-py3.7-linux-x86_64.egg

#############################
# BeakerX Extensions for scala kernel
#############################
RUN pip3 install beakerx==1.4.1 && \
    beakerx install

##############################
# R layers
##############################
COPY --from=R-fs-builder /fs-master.tgz /

RUN set -ex && \
    # Thereis a problem installing R openssl package if libssl1.0 package is installed in the system. 
    # as a temporal patch We temporary delete libssl1.0 package and reinstall.
    #apk del nodejs npm libssl1.0 libcrypto1.0 &&\
    apk add autoconf \
            automake \
            freetype-dev \
            R \
            R-dev \
            linux-headers \
            tzdata && \
    apk add msttcorefonts-installer && update-ms-fonts && \
    #fixing error when getting encoding setting from iconvlist" \
    sed -i 's/,//g' /usr/lib/R/library/utils/iconvlist && \
    R -e "install.packages('Rcpp', repos = 'http://cran.us.r-project.org')" && \
    R -e "install.packages('/fs-master.tgz', repos= NULL, type='source')" && \
    rm /fs-master.tgz && \
    R -e "install.packages('IRkernel', repos = 'http://cran.us.r-project.org')" && \
    R -e "IRkernel::installspec(user = FALSE)" && \
    #R packages for data science (tidyverse)
    R -e "install.packages(c('tidyverse'),repos = 'http://cran.us.r-project.org')" && \
    #R visualization packages
    R -e "install.packages(c('ggridges','plotly','leaflet'),\
      repos = 'http://cran.us.r-project.org')" && \
    #R development packages
    R -e "install.packages('devtools', repos = 'http://cran.us.r-project.org')" 
    #&& \
    #apk add nodejs npm libssl1.0 libcrypto1.0 


EXPOSE 8888
COPY jupyter-conf/ /

RUN apk add --no-cache shadow sudo && \
    adduser -s /bin/bash -h /home/jovyan -D -G $(getent group $NB_GID | awk -F: '{printf $1}') -u $NB_UID $NB_USER && \
    fix-permissions /home/jovyan


ENV HOME=/home/$NB_USER
WORKDIR $HOME
USER $NB_UID


CMD ["start-notebook.sh"]
