public class LeadQueueLogging {
    public static final Boolean ENABLED = false;

    public static void debug(String message) {
        if (ENABLED) {
            System.debug(LoggingLevel.DEBUG, message);
        }
    }
}
