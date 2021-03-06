/// -*- tab-width: 4; Mode: C++; c-basic-offset: 4; indent-tabs-mode: nil -*-

#define THISFIRMWARE "ArduPlane V2.68"
/*
 *  Authors:    Doug Weibel, Jose Julio, Jordi Munoz, Jason Short, Andrew Tridgell, 
 *              Randy Mackay, Pat Hickey, John Arne Birkeland, Olivier Adler, 
 *		Amilcar Lucas, Gregory Fletcher
 *  Thanks to:  Chris Anderson, Michael Oborne, Paul Mather, Bill Premerlani, 
 *		James Cohen, JB from rotorFX, Automatik, Fefenin, Peter Meister, 
 *		Remzibi, Yury Smirnov, Sandro Benigno, Max Levine, Roberto Navoni, 
 *		Lorenz Meier, Yury MonZon
 *  Please contribute your ideas!
 *
 *
 *  This firmware is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, or (at your option) any later version.
 */

 /*****************************************************************************
  * 在APM飞控系统中，采用的是两极PID控制方式，第一级是导航级，第二级是控制级，
  * 导航级的计算集中在medium_loop()和fastloop()的update_current_flight_mode()
  * 函数中，控制级集中在fast_loop的stabilize()函数中。导航级PID控制就是要解决
  * 飞机如何一预定空速飞行在预定高度的问题，以及如何转弯飞往目标问题，通过算法
  * 给出飞机需要的俯仰角、油门和横滚角，然后交给控制级进行控制计算。控制级的任
  * 务就是依据需要的俯仰角、横滚角油门，结合飞机当前的姿态计算出合适的舵机控制
  * 量，使飞机保持预定的俯仰角、横滚角和方向角。最后通过舵机控制级set_servos_4()
  * 将控制量转换成具体的pwm信号量输出给舵机。值得一提的是，油门的控制量是在导航
  * 级确定的。控制级中不对油门控制量进行计算，而直接交给舵机控制级。而对于方向舵
  * 的控制，导航级并不给出方向舵量的计算，而是由控制级直接计算方向舵控制量，然后
  * 再交给舵机控制级。  
  */


////////////////////////////////////////////////////////////////////////////////
// Header includes
////////////////////////////////////////////////////////////////////////////////

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
                                      /********关注的库*********/
#include <AP_Common.h>                // 通用库，通用的结构体
#include <AP_Progmem.h>               // 一些C库的补充和校正
#include <AP_HAL.h>                   // 硬件模块库，包含所有硬件模块的虚拟方法（比较特殊），C++类封装
#include <AP_Menu.h>                  // 一个CLI命令行接口菜单的实现库
#include <AP_Param.h>                 // 管理和保存系统感兴趣的一些变量 EEPROM
#include <AP_GPS.h>                   // GPS模块库
#include <AP_Baro.h>                  // Baromter气压传感器模块库
#include <AP_Compass.h>               // 磁力计模块库
#include <AP_Math.h>                  // 向量和矩阵数学库
#include <AP_ADC.h>                   // AD转换底层库
#include <AP_ADC_AnalogSource.h>      // 获取ADC挂接设备的数据的方法实现
#include <AP_InertialSensor.h>        // 惯性传感器模块库
#include <AP_AHRS.h>                  // DCM算法库
#include <PID.h>                      // PID算法库
#include <RC_Channel.h>               // RC通道库
#include <AP_RangeFinder.h>           // 测距仪模块库 包括超声波
#include <Filter.h>                   // 滤波算法库
#include <AP_Buffer.h>                // FIFO缓冲库
#include <AP_Relay.h>                 // 继电器控制库
#include <AP_Camera.h>                // 摄像头模块库
#include <AP_Airspeed.h>              // 空速模块库
#include <memcheck.h>                 // 内存检测库

#include <APM_OBC.h>                  // 故障保护库
#include <APM_Control.h>              // 三个姿态角的控制库
#include <GCS_MAVLink.h>              // MAVLink库
#include <AP_Mount.h>                 // 载具控制库
#include <AP_Declination.h>           // 偏差库
#include <DataFlash.h>                // 日志等黑匣子库
#include <SITL.h>                     // 软件在环库：http://code.google.com/p/ardupilot-mega/wiki/SITL?wl=zh-Hans

// optional new controller library
#if APM_CONTROL == ENABLED
#include <APM_Control.h>
#endif

// Pre-AP_HAL compatibility 兼容性
#include "compat.h"

// Configuration
#include "config.h"

// Local modules
// 本地的，全局的，重要的类定义
#include "defines.h"
#include "Parameters.h"
#include "GCS.h"

#include <AP_HAL_AVR.h>
#include <AP_HAL_AVR_SITL.h>
#include <AP_HAL_PX4.h>
#include <AP_HAL_Empty.h>

AP_HAL::BetterStream* cliSerial; //一个流作为命令行接口的串口，实例

const AP_HAL::HAL& hal = AP_HAL_BOARD_DRIVER;


////////////////////////////////////////////////////////////////////////////////
// Outback Challenge Failsafe Support
////////////////////////////////////////////////////////////////////////////////
#if OBC_FAILSAFE == ENABLED
APM_OBC obc;//声明失效保护对象
#endif

////////////////////////////////////////////////////////////////////////////////
// the rate we run the main loop at 惯性测量传感单元的更新速度50HZ
////////////////////////////////////////////////////////////////////////////////
//来自AP_InertialSensor类，该类下包含了惯性单元的各种方法
static const AP_InertialSensor::Sample_rate ins_sample_rate = AP_InertialSensor::RATE_50HZ;

////////////////////////////////////////////////////////////////////////////////
// Parameters
////////////////////////////////////////////////////////////////////////////////
//
// Global parameters are all contained within the 'g' class.
// 声明全局变量
static Parameters g;

////////////////////////////////////////////////////////////////////////////////
// prototypes
static void update_events(void);


////////////////////////////////////////////////////////////////////////////////
// DataFlash  声明Flash对象
////////////////////////////////////////////////////////////////////////////////
#if CONFIG_HAL_BOARD == HAL_BOARD_APM1
DataFlash_APM1 DataFlash;
#elif CONFIG_HAL_BOARD == HAL_BOARD_APM2
DataFlash_APM2 DataFlash;
#elif CONFIG_HAL_BOARD == HAL_BOARD_AVR_SITL
DataFlash_SITL DataFlash;
#else
// no dataflash driver
DataFlash_Empty DataFlash;
#endif

////////////////////////////////////////////////////////////////////////////////
// Sensors
////////////////////////////////////////////////////////////////////////////////
//
// There are three basic options related to flight sensor selection.
//
// - Normal flight mode.  Real sensors are used.
// - HIL Attitude mode.  Most sensors are disabled, as the HIL
//   protocol supplies attitude information directly.
// - HIL Sensors mode.  Synthetic sensors are configured that
//   supply data from the simulation.
//

// All GPS access should be through this pointer.
// 声明GPS对象
static GPS         *g_gps;

// flight modes convenience array
// 声明飞机模式
static AP_Int8          *flight_modes = &g.flight_mode1;
// 真实模式下的声明--------------------
#if HIL_MODE == HIL_MODE_DISABLED

// real sensors
 #if CONFIG_ADC == ENABLED
static AP_ADC_ADS7844 adc;
 #endif

 # if CONFIG_HAL_BOARD == HAL_BOARD_AVR_SITL
AP_Baro_BMP085_HIL barometer;
AP_Compass_HIL compass;
AP_InertialSensor_Stub ins;
SITL sitl;
 #else

  #if CONFIG_BARO == AP_BARO_BMP085
static AP_Baro_BMP085 barometer;
  #elif CONFIG_BARO == AP_BARO_PX4
static AP_Baro_PX4 barometer;
  #elif CONFIG_BARO == AP_BARO_MS5611
   #if CONFIG_MS5611_SERIAL == AP_BARO_MS5611_SPI
static AP_Baro_MS5611 barometer(&AP_Baro_MS5611::spi);
   #elif CONFIG_MS5611_SERIAL == AP_BARO_MS5611_I2C
static AP_Baro_MS5611 barometer(&AP_Baro_MS5611::i2c);
   #else
    #error Unrecognized CONFIG_MS5611_SERIAL setting.
   #endif
  #endif

#if CONFIG_HAL_BOARD == HAL_BOARD_PX4
static AP_Compass_PX4 compass;
#else
static AP_Compass_HMC5843 compass;
#endif
 #endif
// 根据配置确定GPS的具体协议
//根据GPS的不同型号来确定具体的协议
// real GPS selection
 #if   GPS_PROTOCOL == GPS_PROTOCOL_AUTO
AP_GPS_Auto     g_gps_driver(&g_gps);

 #elif GPS_PROTOCOL == GPS_PROTOCOL_NMEA
AP_GPS_NMEA     g_gps_driver();

 #elif GPS_PROTOCOL == GPS_PROTOCOL_SIRF
AP_GPS_SIRF     g_gps_driver();

 #elif GPS_PROTOCOL == GPS_PROTOCOL_UBLOX
AP_GPS_UBLOX    g_gps_driver();

 #elif GPS_PROTOCOL == GPS_PROTOCOL_MTK
AP_GPS_MTK      g_gps_driver();

 #elif GPS_PROTOCOL == GPS_PROTOCOL_MTK19
AP_GPS_MTK19    g_gps_driver();

 #elif GPS_PROTOCOL == GPS_PROTOCOL_NONE
AP_GPS_None     g_gps_driver();

 #else
  #error Unrecognised GPS_PROTOCOL setting.
 #endif // GPS PROTOCOL

// 根据配置确定惯性传感单元类型
 # if CONFIG_INS_TYPE == CONFIG_INS_MPU6000
AP_InertialSensor_MPU6000 ins;
 # elif CONFIG_INS_TYPE == CONFIG_INS_PX4
AP_InertialSensor_PX4 ins;
 # elif CONFIG_HAL_BOARD != HAL_BOARD_AVR_SITL
AP_InertialSensor_Oilpan ins( &adc );
 #endif // CONFIG_INS_TYPE
// 声明AHRS的DCM算法，可以看到需要惯性单元和GPS
AP_AHRS_DCM ahrs(&ins, g_gps);

#elif HIL_MODE == HIL_MODE_SENSORS
// sensor emulators
AP_Baro_BMP085_HIL barometer;
AP_Compass_HIL compass;
AP_GPS_HIL              g_gps_driver;
AP_InertialSensor_Stub ins;
AP_AHRS_DCM  ahrs(&ins, g_gps);

#elif HIL_MODE == HIL_MODE_ATTITUDE
AP_Baro_BMP085_HIL barometer;
AP_Compass_HIL compass;
AP_GPS_HIL              g_gps_driver;
AP_InertialSensor_Stub ins;
AP_AHRS_HIL   ahrs(&ins, g_gps);

#else
 #error Unrecognised HIL_MODE setting.
#endif // HIL MODE

// Training mode
static bool training_manual_roll;  // user has manual roll control
static bool training_manual_pitch; // user has manual pitch control

////////////////////////////////////////////////////////////////////////////////
// GCS selection
////////////////////////////////////////////////////////////////////////////////
// 声明地面站对象
GCS_MAVLINK gcs0;
GCS_MAVLINK gcs3;

////////////////////////////////////////////////////////////////////////////////
// Analog Inputs
////////////////////////////////////////////////////////////////////////////////
// 声明ADC输入源对象
AP_HAL::AnalogSource *pitot_analog_source;

// a pin for reading the receiver RSSI voltage. The scaling by 0.25 
// is to take the 0 to 1024 range down to an 8 bit range for MAVLink
AP_HAL::AnalogSource *rssi_analog_source;

AP_HAL::AnalogSource *vcc_pin;

AP_HAL::AnalogSource * batt_volt_pin;
AP_HAL::AnalogSource * batt_curr_pin;

////////////////////////////////////////////////////////////////////////////////
// Relay
////////////////////////////////////////////////////////////////////////////////
// 声明继电器对象
AP_Relay relay;

//声明摄像头对象
// Camera
#if CAMERA == ENABLED
AP_Camera camera(&relay);
#endif

////////////////////////////////////////////////////////////////////////////////
// Global variables
////////////////////////////////////////////////////////////////////////////////
// 全局变量声明
// APM2 only
#if USB_MUX_PIN > 0
static bool usb_connected;
#endif
// 遥控接口
/* Radio values
 *               Channel assignments
 *                       1   Ailerons
 *                       2   Elevator
 *                       3   Throttle
 *                       4   Rudder
 *                       5   Aux5
 *                       6   Aux6
 *                       7   Aux7
 *                       8   Aux8/Mode
 *               Each Aux channel can be configured to have any of the available auxiliary functions assigned to it.
 *               See libraries/RC_Channel/RC_Channel_aux.h for more information
 */

////////////////////////////////////////////////////////////////////////////////
// Radio
////////////////////////////////////////////////////////////////////////////////
// This is the state of the flight control system
// There are multiple states defined such as MANUAL, FBW-A, AUTO
enum FlightMode control_mode  = INITIALISING;
// Used to maintain the state of the previous control switch position
// This is set to -1 when we need to re-read the switch
uint8_t oldSwitchPosition;
// This is used to enable the inverted flight feature
bool inverted_flight     = false;
// These are trim values used for elevon control
// For elevons radio_in[CH_ROLL] and radio_in[CH_PITCH] are equivalent aileron and elevator, not left and right elevon
static uint16_t elevon1_trim  = 1500;
static uint16_t elevon2_trim  = 1500;
// These are used in the calculation of elevon1_trim and elevon2_trim
static uint16_t ch1_temp      = 1500;
static uint16_t ch2_temp        = 1500;
// These are values received from the GCS if the user is using GCS joystick
// control and are substituted for the values coming from the RC radio
static int16_t rc_override[8] = {0,0,0,0,0,0,0,0};
// A flag if GCS joystick control is in use
static bool rc_override_active = false;
// 失控保护
////////////////////////////////////////////////////////////////////////////////
// Failsafe
////////////////////////////////////////////////////////////////////////////////
// A tracking variable for type of failsafe active
// Used for failsafe based on loss of RC signal or GCS signal
static int16_t failsafe;
// Used to track if the value on channel 3 (throtttle) has fallen below the failsafe threshold
// RC receiver should be set up to output a low throttle value when signal is lost
static bool ch3_failsafe;
// A timer used to help recovery from unusual attitudes.  If we enter an unusual attitude
// while in autonomous flight this variable is used  to hold roll at 0 for a recovery period
static uint8_t crash_timer;

// the time when the last HEARTBEAT message arrived from a GCS
static uint32_t last_heartbeat_ms;

// A timer used to track how long we have been in a "short failsafe" condition due to loss of RC signal
static uint32_t ch3_failsafe_timer = 0;
// LED
////////////////////////////////////////////////////////////////////////////////
// LED output
////////////////////////////////////////////////////////////////////////////////
// state of the GPS light (on/off)
static bool GPS_light;

////////////////////////////////////////////////////////////////////////////////
// GPS variables
////////////////////////////////////////////////////////////////////////////////
// This is used to scale GPS values for EEPROM storage
// 10^7 times Decimal GPS means 1 == 1cm
// This approximation makes calculations integer and it's easy to read
static const float t7                        = 10000000.0;
// We use atan2 and other trig techniques to calaculate angles
// A counter used to count down valid gps fixes to allow the gps estimate to settle
// before recording our home position (and executing a ground start if we booted with an air start)
//当卫星数达到5颗时，才能找到home的位置？
static uint8_t ground_start_count      = 5;
// Used to compute a speed estimate from the first valid gps fixes to decide if we are
// on the ground or in the air.  Used to decide if a ground start is appropriate if we
// booted with an air start.
static int16_t ground_start_avg;

// true if we have a position estimate from AHRS
static bool have_position;

////////////////////////////////////////////////////////////////////////////////
// Location & Navigation
////////////////////////////////////////////////////////////////////////////////
// Constants
const float radius_of_earth   = 6378100;        // meters

// This is the currently calculated direction to fly.
// deg * 100 : 0 to 360
static int32_t nav_bearing_cd;//当前计算的飞行的方向

// This is the direction to the next waypoint or loiter center
// deg * 100 : 0 to 360
static int32_t target_bearing_cd;//下一个航点和盘旋中心的方向

//This is the direction from the last waypoint to the next waypoint
// deg * 100 : 0 to 360
static int32_t crosstrack_bearing_cd;//最新航点到下一航点的方向

// Direction held during phases of takeoff and landing起飞和降落的相位的方向 
// deg * 100 dir of plane,  A value of -1 indicates the course has not been set/is not in use
static int32_t hold_course                   = -1;              // deg * 100 dir of plane

// There may be two active commands in Auto mode.自动模式分为两种，一种有导航命令，一种无导航命令
// This indicates the active navigation command by index number
static uint8_t nav_command_index;
// This indicates the active non-navigation command by index number
static uint8_t non_nav_command_index;
// This is the command type (eg navigate to waypoint) of the active navigation command
static uint8_t nav_command_ID          = NO_COMMAND;
static uint8_t non_nav_command_ID      = NO_COMMAND;

////////////////////////////////////////////////////////////////////////////////
// Airspeed
////////////////////////////////////////////////////////////////////////////////
// The calculated airspeed to use in FBW-B.  Also used in higher modes for insuring min ground speed is met.
// Also used for flap deployment criteria.  Centimeters per second.
static int32_t target_airspeed_cm;//计算出的空速值用于FBW

// The difference between current and desired airspeed.  Used in the pitch controller.  Centimeters per second.
static float airspeed_error_cm;//当前和预计的空速的不同，用于俯仰控制

// The calculated total energy error (kinetic (altitude) plus potential (airspeed)).
// Used by the throttle controller
static int32_t energy_error;//计算出的总的电量误差，用于油门控制

// kinetic portion of energy error (m^2/s^2)
static int32_t airspeed_energy_error;//电量误差的运动部分

// An amount that the airspeed should be increased in auto modes based on the user positioning the
// throttle stick in the top half of the range.  Centimeters per second.
static int16_t airspeed_nudge_cm;

// Similar to airspeed_nudge, but used when no airspeed sensor.
// 0-(throttle_max - throttle_cruise) : throttle nudge in Auto mode using top 1/2 of throttle stick travel
static int16_t throttle_nudge = 0;//当没有空速计时使用

// receiver RSSI
static uint8_t receiver_rssi;//接收信号强度


////////////////////////////////////////////////////////////////////////////////
// Ground speed
////////////////////////////////////////////////////////////////////////////////
// The amount current ground speed is below min ground speed.  Centimeters per second
static int32_t groundspeed_undershoot = 0;//当前地面速度小于最小地面速度（最小地面速度应该是起飞时所需的最小速度）

////////////////////////////////////////////////////////////////////////////////
// Location Errors
////////////////////////////////////////////////////////////////////////////////
// Difference between current bearing and desired bearing.  Hundredths of a degree
static int32_t bearing_error_cd;

// Difference between current altitude and desired altitude.  Centimeters
static int32_t altitude_error_cm;//当前高度和期望高度的差

// Distance perpandicular to the course line that we are off trackline.  Meters
static float crosstrack_error;

////////////////////////////////////////////////////////////////////////////////
// Battery Sensors 电压传感器
////////////////////////////////////////////////////////////////////////////////
// Battery pack 1 voltage.  Initialized above the low voltage threshold to pre-load the filter and prevent low voltage events at startup.
static float battery_voltage1        = LOW_VOLTAGE * 1.05;
// Battery pack 1 instantaneous currrent draw.  Amperes
static float current_amps1;
// Totalized current (Amp-hours) from battery 1
static float current_total1;

// To Do - Add support for second battery pack
//static float  battery_voltage2    = LOW_VOLTAGE * 1.05;		// Battery 2 Voltage, initialized above threshold for filter
//static float	current_amps2;									// Current (Amperes) draw from battery 2
//static float	current_total2;									// Totalized current (Amp-hours) from battery 2

////////////////////////////////////////////////////////////////////////////////
// Airspeed Sensors 空速传感器
////////////////////////////////////////////////////////////////////////////////
AP_Airspeed airspeed;

////////////////////////////////////////////////////////////////////////////////
// Altitude Sensor variables
// 飞行模式
////////////////////////////////////////////////////////////////////////////////
// flight mode specific
////////////////////////////////////////////////////////////////////////////////
// Flag for using gps ground course instead of INS yaw.  Set false when takeoff command in process.
static bool takeoff_complete    = true;
// Flag to indicate if we have landed.
//Set land_complete if we are within 2 seconds distance or within 3 meters altitude of touchdown
static bool land_complete;
// Altitude threshold to complete a takeoff command in autonomous modes.  Centimeters
static int32_t takeoff_altitude;

// Minimum pitch to hold during takeoff command execution.  Hundredths of a degree
static int16_t takeoff_pitch_cd;

// this controls throttle suppression in auto modes
static bool throttle_suppressed;

////////////////////////////////////////////////////////////////////////////////
// Loiter management  盘旋管理
////////////////////////////////////////////////////////////////////////////////
// Previous target bearing.  Used to calculate loiter rotations.  Hundredths of a degree
static int32_t old_target_bearing_cd;

// Total desired rotation in a loiter.  Used for Loiter Turns commands.  Degrees
static int32_t loiter_total;

// The amount in degrees we have turned since recording old_target_bearing
static int16_t loiter_delta;

// Total rotation in a loiter.  Used for Loiter Turns commands and to check for missed waypoints.  Degrees
static int32_t loiter_sum;

// The amount of time we have been in a Loiter.  Used for the Loiter Time command.  Milliseconds.
static uint32_t loiter_time_ms;

// The amount of time we should stay in a loiter for the Loiter Time command.  Milliseconds.
static uint32_t loiter_time_max_ms;

////////////////////////////////////////////////////////////////////////////////
// Navigation control variables  导航控制变量
////////////////////////////////////////////////////////////////////////////////
// The instantaneous desired bank angle.  Hundredths of a degree
static int32_t nav_roll_cd;

// The instantaneous desired pitch angle.  Hundredths of a degree
static int32_t nav_pitch_cd;

////////////////////////////////////////////////////////////////////////////////
// Waypoint distances 航点距离
////////////////////////////////////////////////////////////////////////////////
// Distance between plane and next waypoint.  Meters
// is not static because AP_Camera uses it
int32_t wp_distance;

// Distance between previous and next waypoint.  Meters
//当前航点与下一航点的距离
static int32_t wp_totalDistance;

// event control state  事件控制状态，控制继电器还是伺服系统
enum event_type { 
    EVENT_TYPE_RELAY=0,
    EVENT_TYPE_SERVO=1
};

static struct {
    enum event_type type;

	// when the event was started in ms
    uint32_t start_time_ms;

	// how long to delay the next firing of event in millis
    uint16_t delay_ms;

	// how many times to cycle : -1 (or -2) = forever, 2 = do one cycle, 4 = do two cycles
    int16_t repeat;

    // RC channel for servos 伺服系统的遥控通道
    uint8_t rc_channel;

	// PWM for servos 给伺服系统的PWM波
	uint16_t servo_value;

	// the value used to cycle events (alternate value to event_value)
    uint16_t undo_value;
} event_state;


////////////////////////////////////////////////////////////////////////////////
// Conditional command 特定条件的命令
////////////////////////////////////////////////////////////////////////////////
// A value used in condition commands (eg delay, change alt, etc.)
// For example in a change altitude command, it is the altitude to change to.
static int32_t condition_value;
// A starting value used to check the status of a conditional command.
// For example in a delay command the condition_start records that start time for the delay
static uint32_t condition_start;
// A value used in condition commands.  For example the rate at which to change altitude.
static int16_t condition_rate;

////////////////////////////////////////////////////////////////////////////////
// 3D Location vectors 3D位置向量
// Location structure defined in AP_Common
////////////////////////////////////////////////////////////////////////////////
// The home location used for RTL.  The location is set when we first get stable GPS lock
static struct   Location home;
// Flag for if we have g_gps lock and have set the home location
static bool home_is_set;
// The location of the previous waypoint.  Used for track following and altitude ramp calculations
static struct   Location prev_WP;
// The plane's current location
static struct   Location current_loc;
// The location of the current/active waypoint.  Used for altitude ramp, track following and loiter calculations.
static struct   Location next_WP;
// The location of the active waypoint in Guided mode.
static struct   Location guided_WP;
// The location structure information from the Nav command being processed
static struct   Location next_nav_command;
// The location structure information from the Non-Nav command being processed
static struct   Location next_nonnav_command;

////////////////////////////////////////////////////////////////////////////////
// Altitude / Climb rate control  高度速度控制
////////////////////////////////////////////////////////////////////////////////
// The current desired altitude.  Altitude is linearly ramped between waypoints.  Centimeters
static int32_t target_altitude_cm;
// Altitude difference between previous and current waypoint.  Centimeters
static int32_t offset_altitude_cm;

////////////////////////////////////////////////////////////////////////////////
// INS variables  惯性测量单元变量
////////////////////////////////////////////////////////////////////////////////
// The main loop execution time.  Seconds
//This is the time between calls to the DCM algorithm and is the Integration time for the gyros.
static float G_Dt                                               = 0.02;

////////////////////////////////////////////////////////////////////////////////
// Performance monitoring  性能监视
////////////////////////////////////////////////////////////////////////////////
// Timer used to accrue data and trigger recording of the performanc monitoring log message
static int32_t perf_mon_timer;
// The maximum main loop execution time recorded in the current performance monitoring interval
static int16_t G_Dt_max = 0;
// The number of gps fixes recorded in the current performance monitoring interval
static int16_t gps_fix_count = 0;
// A variable used by developers to track performanc metrics.
// Currently used to record the number of GCS heartbeat messages received
static int16_t pmTest1 = 0;


////////////////////////////////////////////////////////////////////////////////
// System Timers 系统时间
////////////////////////////////////////////////////////////////////////////////
// Time in miliseconds of start of main control loop.  Milliseconds
static uint32_t fast_loopTimer_ms;

// Time Stamp when fast loop was complete.  Milliseconds
static uint32_t fast_loopTimeStamp_ms;

// Number of milliseconds used in last main loop cycle
static uint8_t delta_ms_fast_loop;

// Counter of main loop executions.  Used for performance monitoring and failsafe processing
static uint16_t mainLoop_count;

// Time in miliseconds of start of medium control loop.  Milliseconds
static uint32_t medium_loopTimer_ms;

// Counters for branching from main control loop to slower loops
static uint8_t medium_loopCounter;
// Number of milliseconds used in last medium loop cycle
static uint8_t delta_ms_medium_loop;

// Counters for branching from medium control loop to slower loops
static uint8_t slow_loopCounter;
// Counter to trigger execution of very low rate processes
static uint8_t superslow_loopCounter;
// Counter to trigger execution of 1 Hz processes
static uint8_t counter_one_herz;

// % MCU cycles used
static float load;


// Camera/Antenna mount tracking and stabilisation stuff
// --------------------------------------
#if MOUNT == ENABLED
// current_loc uses the baro/gps soloution for altitude rather than gps only.
// mabe one could use current_loc for lat/lon too and eliminate g_gps alltogether?
AP_Mount camera_mount(&current_loc, g_gps, &ahrs, 0);
#endif

#if MOUNT2 == ENABLED
// current_loc uses the baro/gps soloution for altitude rather than gps only.
// mabe one could use current_loc for lat/lon too and eliminate g_gps alltogether?
AP_Mount camera_mount2(&current_loc, g_gps, &ahrs, 1);
#endif

#if CAMERA == ENABLED
//pinMode(camtrig, OUTPUT);			// these are free pins PE3(5), PH3(15), PH6(18), PB4(23), PB5(24), PL1(36), PL3(38), PA6(72), PA7(71), PK0(89), PK1(88), PK2(87), PK3(86), PK4(83), PK5(84), PK6(83), PK7(82)
#endif

////////////////////////////////////////////////////////////////////////////////
// Top-level logic 顶层逻辑.......
////////////////////////////////////////////////////////////////////////////////

// setup the var_info table
// ？载入来自EEPROM的1028个字节,1028个字节之后都是放置航点信息？
// 该函数继承AP_Param类下的AP_Param()函数,载入到_var_info中
//初始化一个信息表var_info,并去检测表的大小
AP_Param param_loader(var_info, WP_START_BYTE);

void setup() {
    cliSerial = hal.console;//CLI接收来自HAL的console对象

    // load the default values of variables listed in var_info[]

  
    /*setup_sketch_defaults()首先
  调用函数setup（），去检测EEPROM的头，EEPROM的三个值是固定的，hdr.magic[0] 
 和hdr.magic[1]和hdr.revision是固定的，如果不正确的话就擦除EEPROM，在setup（）
 中的到了var的数量即vars_num， */
    AP_Param::setup_sketch_defaults();//加载默认值

    // 设置ADC的输入源，并设置其分频
    rssi_analog_source = hal.analogin->channel(ANALOG_INPUT_NONE, 0.25);

#if CONFIG_PITOT_SOURCE == PITOT_SOURCE_ADC
    pitot_analog_source = new AP_ADC_AnalogSource( &adc,
                                         CONFIG_PITOT_SOURCE_ADC_CHANNEL, 1.0);
#elif CONFIG_PITOT_SOURCE == PITOT_SOURCE_ANALOG_PIN
    pitot_analog_source = hal.analogin->channel(CONFIG_PITOT_SOURCE_ANALOG_PIN, 4.0);
#endif
    vcc_pin = hal.analogin->channel(ANALOG_INPUT_BOARD_VCC);

    batt_volt_pin = hal.analogin->channel(g.battery_volt_pin);
    batt_curr_pin = hal.analogin->channel(g.battery_curr_pin);
    

    airspeed.init(pitot_analog_source);//空速初始化，参考AP_Airspeed.h
    memcheck_init();//初始化诊断内存，设置标志位

    /*init_ardupilot()中有一个函数load_parameters()在这个函数中，将EEPROM中的值
	载入到_var_info中，而_var_info 和var_info是可以映射过去的，至此我们就将
   EEPROM的值load了出来，*/
    init_ardupilot();//参考system.pde

}

void loop()
{
    // We want this to execute at 50Hz, but synchronised with the gyro/accel
	//以50hz的频率执行，和陀螺仪、加速度计同步
    uint16_t num_samples = ins.num_samples_available();
    if (num_samples >= 1) {
        delta_ms_fast_loop      = millis() - fast_loopTimer_ms;
        load                = (float)(fast_loopTimeStamp_ms - fast_loopTimer_ms)/delta_ms_fast_loop;
        G_Dt                = (float)delta_ms_fast_loop / 1000.f;//陀螺仪积分时间
        fast_loopTimer_ms   = millis();
        mainLoop_count++;

        // Execute the fast loop
	//控制级
        // ---------------------
        fast_loop();

        // Execute the medium loop
	//导航级
        // -----------------------
        medium_loop();

        counter_one_herz++;
        if(counter_one_herz == 50) {
            one_second_loop();
            counter_one_herz = 0;
        }

        if (millis() - perf_mon_timer > 20000) {
            if (mainLoop_count != 0) {
                if (g.log_bitmask & MASK_LOG_PM)
                    Log_Write_Performance();
                    resetPerfData();
            }
        }

        fast_loopTimeStamp_ms = millis();
    } else if (millis() - fast_loopTimeStamp_ms < 19) {
        // less than 19ms has passed. We have at least one millisecond
        // of free time. The most useful thing to do with that time is
        // to accumulate some sensor readings, specifically the
        // compass, which is often very noisy but is not interrupt
        // driven, so it can't accumulate readings by itself
        if (g.compass_enabled) {
            compass.accumulate();
        }
    }
}


// Main loop 50Hz
static void fast_loop()
{
    // This is the fast loop - we want it to execute at 50Hz if possible
    // -----------------------------------------------------------------
    if (delta_ms_fast_loop > G_Dt_max)
        G_Dt_max = delta_ms_fast_loop;

    // Read radio
    // 读取遥控信号，各个通道接收数据----------
    read_radio();

    // try to send any deferred messages if the serial port now has
    // some space available
	/*说明：程序中声明了两个gcs：gcs0和gcs3，初始化时确定哪个gcs使能，
	如果现在串行口有一定的可用空间，尝试发送延迟消息*/
    gcs_send_message(MSG_RETRY_DEFERRED);

    // check for loss of control signal failsafe condition
    // ------------------------------------
    check_short_failsafe();//检查丢失控制信号故障安全的条件的损失。

#if HIL_MODE == HIL_MODE_SENSORS
    // update hil before AHRS update
    gcs_update();
#endif

    ahrs.update();

    // uses the yaw from the DCM to give more accurate turns
    calc_bearing_error();

    if (g.log_bitmask & MASK_LOG_ATTITUDE_FAST)
        Log_Write_Attitude(ahrs.roll_sensor, ahrs.pitch_sensor, ahrs.yaw_sensor);

    if (g.log_bitmask & MASK_LOG_RAW)
        Log_Write_Raw();

    // inertial navigation
    // ------------------
#if INERTIAL_NAVIGATION == ENABLED
    // TODO: implement inertial nav function
    inertialNavigation();//惯性导航，实施惯性导航功能
#endif

    // custom code/exceptions for flight modes
    // ---------------------------------------
    update_current_flight_mode();

    // apply desired roll, pitch and yaw to the plane
    // ----------------------------------------------
    if (control_mode > MANUAL)
        stabilize();//应用飞机的滚转、俯仰 偏航参数

    // write out the servo PWM values
    // ------------------------------
    set_servos();//设置在当前计算值下的基础上的飞行控制伺服
   /*gcs_udate()是一个非常重要的函数，gcs_update函数中包含了两个函数gcs0_update
	和gcs3_update，而gcs0和gcs3都是继承的GCS_MAVLINK,也就继承了GCS_MAVLINK
	的update，update函数中包含了消息处理函数--handdlemessage（），消息处理
	函数处理的消息是通过串口接收得到，串口的中断处理函数中，将串口的得到的
	值先放到一个缓冲区内，然后在消息处理函数中，我们再去一个字节一个字节的
	读取，判断，并做相应的处理，send_message（）*/
    gcs_update();
  
	/*gcs_data_stream_send()是以固定的格式发送的数据流，包含10部分的内容
       包括陀螺仪，加速度计的数据，实时模式，电池电压，当前的位置（经度，
	纬度，高度），自驾仪当前的伺服输出，当前遥控输入值，当前GPS状态，当前
	航点，当前的滚转，俯仰，偏航角*/
    gcs_data_stream_send();//以给定的速率发送数据流
}


/*medium_loop()，这是飞控系统的另外一个核心，执行频率10hz。用于执行GPS数据和磁
力计数据的更新、根据GPS数据进行导航计算、更新高度信息和命令、像地面发送无限数
传数据、控制slow_loop()执行和其他。其中对导航起很重要作用的导航航向的计算就在
mediun_loop()中执行*/
static void medium_loop()
{
#if MOUNT == ENABLED
    camera_mount.update_mount_position();
#endif

#if MOUNT2 == ENABLED
    camera_mount2.update_mount_position();
#endif

#if CAMERA == ENABLED
    camera.trigger_pic_cleanup();
#endif

    // This is the start of the medium (10 Hz) loop pieces
    // -----------------------------------------
    switch(medium_loopCounter) {

    // This case deals with the GPS
    //GPS的处理命令-------------------------------
    case 0:
        medium_loopCounter++;
        update_GPS();
        calc_gndspeed_undershoot();

#if HIL_MODE != HIL_MODE_ATTITUDE
        if (g.compass_enabled && compass.read()) {
            ahrs.set_compass(&compass);
            compass.null_offsets();
        } else {
            ahrs.set_compass(NULL);
        }
#endif

        break;

    // This case performs some navigation computations
    //导航计算------------------------------------------------
    case 1:
        medium_loopCounter++;

        // Read 6-position switch on radio
        // -------------------------------
        read_control_switch();//sensors.pde

        // calculate the plane's desired bearing
        // -------------------------------------
        navigate();

        break;

    // command processing
    //命令处理------------------------------
    case 2:
        medium_loopCounter++;

        // Read Airspeed
        // -------------
#if HIL_MODE != HIL_MODE_ATTITUDE
        if (airspeed.enabled()) {
            read_airspeed();//参考AP_Airspeed.h  读取模拟源和更新的速度
        }
#endif

        read_receiver_rssi();

        // Read altitude from sensors
        // ------------------
        update_alt();

        // altitude smoothing
        // ------------------
        if (control_mode != FLY_BY_WIRE_B)
            calc_altitude_error();//参考nacigation.pde

        // perform next command
        // --------------------
        update_commands();//commands_process.pde
        break;

    // This case deals with sending high rate telemetry
    //发送高速率的数据信号-------------------------------------------------
    case 3:
        medium_loopCounter++;

        if ((g.log_bitmask & MASK_LOG_ATTITUDE_MED) && !(g.log_bitmask & MASK_LOG_ATTITUDE_FAST))
            Log_Write_Attitude(ahrs.roll_sensor, ahrs.pitch_sensor, ahrs.yaw_sensor);

        if (g.log_bitmask & MASK_LOG_CTUN)
            Log_Write_Control_Tuning();

        if (g.log_bitmask & MASK_LOG_NTUN)
            Log_Write_Nav_Tuning();

        if (g.log_bitmask & MASK_LOG_GPS)
            Log_Write_GPS(g_gps->time, current_loc.lat, current_loc.lng, g_gps->altitude, current_loc.alt, (long) g_gps->ground_speed, g_gps->ground_course, g_gps->fix, g_gps->num_sats);
        break;

    // This case controls the slow loop
    /*控制slow_loop(),slow_loop()函数，执行周期1/3s，主要执行长时间故障安全检
查、读取三段开关、读取舵面正方向及混控开关、读取地面站指令等操作。*/
    case 4:
        medium_loopCounter = 0;
        delta_ms_medium_loop    = millis() - medium_loopTimer_ms;
        medium_loopTimer_ms     = millis();

        if (g.battery_monitoring != 0) {
            read_battery();
        }

        slow_loop();

#if OBC_FAILSAFE == ENABLED
        // perform OBC failsafe checks
        obc.check(OBC_MODE(control_mode),
                  last_heartbeat_ms,
                  g_gps ? g_gps->last_fix_time : 0);
#endif

        break;
    }
}

static void slow_loop()
{
    // This is the slow (3 1/3 Hz) loop pieces
    //----------------------------------------
    switch (slow_loopCounter) {
    case 0:
        slow_loopCounter++;
        check_long_failsafe();
        superslow_loopCounter++;
        if(superslow_loopCounter >=200) {                                               //	200 = Execute every minute
#if HIL_MODE != HIL_MODE_ATTITUDE
            if(g.compass_enabled) {
                compass.save_offsets();
            }
#endif

            superslow_loopCounter = 0;
        }
        break;

    case 1:
        slow_loopCounter++;

#if CONFIG_HAL_BOARD == HAL_BOARD_APM2
        update_aux_servo_function(&g.rc_5, &g.rc_6, &g.rc_7, &g.rc_8, &g.rc_9, &g.rc_10, &g.rc_11);
#else
        update_aux_servo_function(&g.rc_5, &g.rc_6, &g.rc_7, &g.rc_8);
#endif
        enable_aux_servos();

#if MOUNT == ENABLED
        camera_mount.update_mount_type();
#endif
#if MOUNT2 == ENABLED
        camera_mount2.update_mount_type();
#endif
        break;

    case 2:
        slow_loopCounter = 0;
        update_events();

        mavlink_system.sysid = g.sysid_this_mav;                // This is just an ugly hack to keep mavlink_system.sysid sync'd with our parameter

        check_usb_mux();

        break;
    }
}
/*执行周期1s。主要执行记录电池电压、发送CPU使用时间等操作*/
static void one_second_loop()
{
    if (g.log_bitmask & MASK_LOG_CUR)
        Log_Write_Current();

    // send a heartbeat
    gcs_send_message(MSG_HEARTBEAT);
}

static void update_GPS(void)
{
    g_gps->update();
    update_GPS_light();

    // get position from AHRS
    have_position = ahrs.get_position(&current_loc);

    if (g_gps->new_data && g_gps->fix) {
        g_gps->new_data = false;

        // for performance
        // ---------------
        gps_fix_count++;

        if(ground_start_count > 1) {
            ground_start_count--;
            ground_start_avg += g_gps->ground_speed;

        } else if (ground_start_count == 1) {
            // We countdown N number of good GPS fixes
            // so that the altitude is more accurate
            // -------------------------------------
            if (current_loc.lat == 0) {
                ground_start_count = 5;

            } else {
                if(ENABLE_AIR_START == 1 && (ground_start_avg / 5) < SPEEDFILT) {
                    startup_ground();

                    if (g.log_bitmask & MASK_LOG_CMD)
                        Log_Write_Startup(TYPE_GROUNDSTART_MSG);

                    init_home();
                } else if (ENABLE_AIR_START == 0) {
                    init_home();
                }

                if (g.compass_enabled) {
                    // Set compass declination automatically
                    compass.set_initial_location(g_gps->latitude, g_gps->longitude);
                }
                ground_start_count = 0;
            }
        }

        // see if we've breached the geo-fence
        geofence_check(false);
    }
}

static void update_current_flight_mode(void)
{
    if(control_mode == AUTO) {
        crash_checker();

        switch(nav_command_ID) {
        case MAV_CMD_NAV_TAKEOFF:
            if (hold_course != -1 && g.rudder_steer == 0) {
                calc_nav_roll();
            } else {
                nav_roll_cd = 0;
            }

            if (alt_control_airspeed()) {
                calc_nav_pitch();
                if (nav_pitch_cd < takeoff_pitch_cd)
                    nav_pitch_cd = takeoff_pitch_cd;
            } else {
                nav_pitch_cd = (g_gps->ground_speed / (float)g.airspeed_cruise_cm) * takeoff_pitch_cd;
                nav_pitch_cd = constrain_int32(nav_pitch_cd, 500, takeoff_pitch_cd);
            }

#if APM_CONTROL == DISABLED
            float aspeed;
            if (ahrs.airspeed_estimate(&aspeed)) {
                // don't use a pitch/roll integrators during takeoff if we are
                // below minimum speed
                if (aspeed < g.flybywire_airspeed_min) {
                    g.pidServoPitch.reset_I();
                    g.pidServoRoll.reset_I();
                }
            }
#endif

            // max throttle for takeoff
            g.channel_throttle.servo_out = g.throttle_max;

            break;

        case MAV_CMD_NAV_LAND:
            if (g.rudder_steer == 0 || !land_complete) {
                calc_nav_roll();
            } else {
                nav_roll_cd = 0;
            }

            if (land_complete) {
                // hold pitch constant in final approach
                nav_pitch_cd = g.land_pitch_cd;
            } else {
                calc_nav_pitch();
                if (!alt_control_airspeed()) {
                    // when not under airspeed control, don't allow
                    // down pitch in landing
                    nav_pitch_cd = constrain_int32(nav_pitch_cd, 0, nav_pitch_cd);
                }
            }
            calc_throttle();

            if (land_complete) {
                // we are in the final stage of a landing - force
                // zero throttle
                g.channel_throttle.servo_out = 0;
            }
            break;

        default:
            // we are doing normal AUTO flight, the special cases
            // are for takeoff and landing
            hold_course = -1;
            land_complete = false;
            calc_nav_roll();
            calc_nav_pitch();
            calc_throttle();
            break;
        }
    }else{
        // hold_course is only used in takeoff and landing
        hold_course = -1;

        switch(control_mode) {
        case RTL:
        case LOITER:
        case GUIDED:
            crash_checker();
            calc_nav_roll();
            calc_nav_pitch();
            calc_throttle();
            break;

        case TRAINING: {
            training_manual_roll = false;
            training_manual_pitch = false;

            // if the roll is past the set roll limit, then
            // we set target roll to the limit
            if (ahrs.roll_sensor >= g.roll_limit_cd) {
                nav_roll_cd = g.roll_limit_cd;
            } else if (ahrs.roll_sensor <= -g.roll_limit_cd) {
                nav_roll_cd = -g.roll_limit_cd;                
            } else {
                training_manual_roll = true;
                nav_roll_cd = 0;
            }

            // if the pitch is past the set pitch limits, then
            // we set target pitch to the limit
            if (ahrs.pitch_sensor >= g.pitch_limit_max_cd) {
                nav_pitch_cd = g.pitch_limit_max_cd;
            } else if (ahrs.pitch_sensor <= g.pitch_limit_min_cd) {
                nav_pitch_cd = g.pitch_limit_min_cd;
            } else {
                training_manual_pitch = true;
                nav_pitch_cd = 0;
            }
            if (inverted_flight) {
                nav_pitch_cd = -nav_pitch_cd;
            }
            break;
        }

        case FLY_BY_WIRE_A: {
            // set nav_roll and nav_pitch using sticks
            nav_roll_cd  = g.channel_roll.norm_input() * g.roll_limit_cd;
            float pitch_input = g.channel_pitch.norm_input();
            if (pitch_input > 0) {
                nav_pitch_cd = pitch_input * g.pitch_limit_max_cd;
            } else {
                nav_pitch_cd = -(pitch_input * g.pitch_limit_min_cd);
            }
            nav_pitch_cd = constrain_int32(nav_pitch_cd, g.pitch_limit_min_cd.get(), g.pitch_limit_max_cd.get());
            if (inverted_flight) {
                nav_pitch_cd = -nav_pitch_cd;
            }
            break;
        }

        case FLY_BY_WIRE_B:
            // Substitute stick inputs for Navigation control output
            // We use g.pitch_limit_min because its magnitude is
            // normally greater than g.pitch_limit_max

            // Thanks to Yury MonZon for the altitude limit code!

            nav_roll_cd = g.channel_roll.norm_input() * g.roll_limit_cd;

            float elevator_input;
            elevator_input = g.channel_pitch.norm_input();

            if (g.flybywire_elev_reverse) {
                elevator_input = -elevator_input;
            }
            if ((adjusted_altitude_cm() >= home.alt+g.FBWB_min_altitude_cm) || (g.FBWB_min_altitude_cm == 0)) {
                altitude_error_cm = elevator_input * g.pitch_limit_min_cd;
            } else {
                altitude_error_cm = (home.alt + g.FBWB_min_altitude_cm) - adjusted_altitude_cm();
                if (elevator_input < 0) {
                    altitude_error_cm += elevator_input * g.pitch_limit_min_cd;
                }
            }
            calc_throttle();
            calc_nav_pitch();
            break;

        case STABILIZE:
            nav_roll_cd        = 0;
            nav_pitch_cd       = 0;
            // throttle is passthrough
            break;

        case CIRCLE:
            // we have no GPS installed and have lost radio contact
            // or we just want to fly around in a gentle circle w/o GPS
            // ----------------------------------------------------
            nav_roll_cd  = g.roll_limit_cd / 3;
            nav_pitch_cd = 0;

            if (failsafe != FAILSAFE_NONE) {
                g.channel_throttle.servo_out = g.throttle_cruise;
            }
            break;

        case MANUAL:
            // servo_out is for Sim control only
            // ---------------------------------
            g.channel_roll.servo_out = g.channel_roll.pwm_to_angle();
            g.channel_pitch.servo_out = g.channel_pitch.pwm_to_angle();
            g.channel_rudder.servo_out = g.channel_rudder.pwm_to_angle();
            break;
            //roll: -13788.000,  pitch: -13698.000,   thr: 0.000, rud: -13742.000

        case INITIALISING:
        case AUTO:
            // handled elsewhere
            break;
        }
    }
}

static void update_navigation()
{
    // wp_distance is in ACTUAL meters, not the *100 meters we get from the GPS
    // ------------------------------------------------------------------------

    // distance and bearing calcs only
    switch(control_mode) {
    case AUTO:
        verify_commands();
        break;
            
    case LOITER:
    case RTL:
    case GUIDED:
        update_loiter();
        calc_bearing_error();
        break;

    case MANUAL:
    case STABILIZE:
    case TRAINING:
    case INITIALISING:
    case FLY_BY_WIRE_A:
    case FLY_BY_WIRE_B:
    case CIRCLE:
        // nothing to do
        break;
    }
}


static void update_alt()
{
#if HIL_MODE == HIL_MODE_ATTITUDE
    current_loc.alt = g_gps->altitude;
#else
    // this function is in place to potentially add a sonar sensor in the future
    //altitude_sensor = BARO;

    if (barometer.healthy) {
        current_loc.alt = (1 - g.altitude_mix) * g_gps->altitude;                       // alt_MSL centimeters (meters * 100)
        current_loc.alt += g.altitude_mix * (read_barometer() + home.alt);
    } else if (g_gps->fix) {
        current_loc.alt = g_gps->altitude;     // alt_MSL centimeters (meters * 100)
    }
#endif

    geofence_check(true);

    // Calculate new climb rate
    //if(medium_loopCounter == 0 && slow_loopCounter == 0)
    //	add_altitude_data(millis() / 100, g_gps->altitude / 10);
}

AP_HAL_MAIN();
