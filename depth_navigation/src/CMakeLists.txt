cmake_minimum_required(VERSION 3.8)
project(midas_nav)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic -O3)
endif()

# Find dependencies
find_package(ament_cmake REQUIRED)
find_package(ament_cmake_python REQUIRED)
find_package(rclcpp REQUIRED)
find_package(rclpy REQUIRED)
find_package(std_msgs REQUIRED)
find_package(sensor_msgs REQUIRED)
find_package(geometry_msgs REQUIRED)
find_package(tf2_ros REQUIRED)
find_package(OpenCV REQUIRED)

# Find DNN node library
find_library(DNN_NODE_LIB dnn_node
  PATHS /opt/tros/humble/lib
  NO_DEFAULT_PATH
)

# Find BPU libraries
find_library(HB_DNN_LIB dnn
  PATHS /usr/lib
  NO_DEFAULT_PATH
)

find_library(HB_DNNPY_LIB dnnpy
  PATHS /usr/lib
  NO_DEFAULT_PATH
)

# C++ MiDaS depth node
add_executable(midas_depth_cpp
  src/midas_depth_node.cpp
)

target_include_directories(midas_depth_cpp PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>
  /opt/tros/humble/include
  ${OpenCV_INCLUDE_DIRS}
)

target_link_libraries(midas_depth_cpp
  ${DNN_NODE_LIB}
  ${HB_DNN_LIB}
  ${HB_DNNPY_LIB}
  ${OpenCV_LIBRARIES}
)

ament_target_dependencies(midas_depth_cpp
  rclcpp
  std_msgs
  sensor_msgs
)

# Install C++ executables
install(TARGETS
  midas_depth_cpp
  DESTINATION lib/${PROJECT_NAME}
)

# Install Python modules
ament_python_install_package(${PROJECT_NAME})

# Install Python executables
install(PROGRAMS
  midas_nav/static_tf_publisher.py
  midas_nav/odom_tf_bridge.py
  DESTINATION lib/${PROJECT_NAME}
)

# Install launch files
install(DIRECTORY
  launch
  DESTINATION share/${PROJECT_NAME}
)

# Install config files
install(DIRECTORY
  config
  DESTINATION share/${PROJECT_NAME}
)

# Install RViz config
install(DIRECTORY
  rviz
  DESTINATION share/${PROJECT_NAME}
)

if(BUILD_TESTING)
  find_package(ament_lint_auto QUIET)
  if(ament_lint_auto_FOUND)
    ament_lint_auto_find_test_dependencies()
  endif()
endif()

ament_package()
