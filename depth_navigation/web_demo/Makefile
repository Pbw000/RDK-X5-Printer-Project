# MiDaS Web Demo — C++ Makefile for RDK X5
# Build: make
# Clean: make clean
# Run:   ./midas_web_demo

CXX = g++
TARGET = midas_web_demo
SRC = web_demo.cpp

# OpenCV — only link what we need
OPENCV_CFLAGS := $(shell pkg-config --cflags opencv4 2>/dev/null || echo "-I/usr/include/opencv4")
OPENCV_LIBS = -lopencv_core -lopencv_imgproc -lopencv_videoio -lopencv_imgcodecs

# BPU DNN
DNN_INCLUDE = -I/usr/include
DNN_LIBS = -ldnn -lhbrt_bayes_aarch64

CXXFLAGS = -std=c++17 -O2 -Wall -Wno-unused-result $(OPENCV_CFLAGS) $(DNN_INCLUDE)
LDFLAGS = $(OPENCV_LIBS) $(DNN_LIBS) -lpthread

all: $(TARGET)

$(TARGET): $(SRC)
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET)

run: $(TARGET)
	./$(TARGET)

.PHONY: all clean run
